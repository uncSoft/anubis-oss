//
//  LMStudioNativeStream.swift
//  anubis
//
//  Created on 2026-08-22.
//

import Foundation

/// Parser for LM Studio's native chat API (`POST /api/v1/chat`, LM Studio
/// 0.4.0+), which — unlike the OpenAI-compat `/v1/chat/completions` endpoint —
/// reports decode timing measured inside the server: `tokens_per_second`,
/// `time_to_first_token_seconds` (excludes model load, matching methodology
/// v3), `model_load_time_seconds`, and real input/output/reasoning token
/// counts. LM Studio is the most common backend on the public leaderboard, so
/// replacing client-side wall-clock estimates here is a large accuracy win.
///
/// The stream is typed SSE: `event: <type>` lines followed by
/// `data: {"type": <type>, ...}`. Every payload carries its type
/// discriminator, so parsing only needs the `data:` lines. Event vocabulary
/// (verified empirically against LM Studio, Aug 2026):
///
///   chat.start
///   model_load.start / model_load.progress / model_load.end {load_time_seconds}
///   prompt_processing.start / .progress / .end
///   reasoning.start / reasoning.delta {content} / reasoning.end
///   message.start / message.delta {content} / message.end
///   chat.end {result: {stats: {...}}}
///
/// Unknown event types are skipped so future LM Studio versions degrade
/// gracefully. Errors arrive as a non-200 response with an OpenAI-style
/// `{"error": {"message": ...}}` body, not as stream events.
struct LMStudioNativeStreamParser {

    // MARK: - Wire types

    struct Event: Codable {
        let type: String
        /// reasoning.delta / message.delta text.
        let content: String?
        /// model_load.end
        let loadTimeSeconds: Double?
        /// chat.end
        let result: ChatResult?

        enum CodingKeys: String, CodingKey {
            case type, content, result
            case loadTimeSeconds = "load_time_seconds"
        }
    }

    struct ChatResult: Codable {
        let stats: Stats?
    }

    struct Stats: Codable {
        let inputTokens: Int?
        let totalOutputTokens: Int?
        let reasoningOutputTokens: Int?
        let tokensPerSecond: Double?
        /// Seconds; measured by the server, EXCLUDES model load time.
        let timeToFirstTokenSeconds: Double?
        /// Present only when this request JIT-loaded the model.
        let modelLoadTimeSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case totalOutputTokens = "total_output_tokens"
            case reasoningOutputTokens = "reasoning_output_tokens"
            case tokensPerSecond = "tokens_per_second"
            case timeToFirstTokenSeconds = "time_to_first_token_seconds"
            case modelLoadTimeSeconds = "model_load_time_seconds"
        }
    }

    // MARK: - State

    private(set) var stats: Stats?
    private(set) var rawStatsJSON: String?
    private(set) var loadTimeSeconds: Double?
    /// Set when chat.end has been seen — the stream is semantically complete.
    private(set) var sawChatEnd = false

    // Local fallback counters, used only if the stream dies before chat.end.
    private(set) var reasoningPieces = 0
    private(set) var outputPieces = 0
    private var reasoningStart: Date?
    private var reasoningEnd: Date?

    // MARK: - Parsing

    /// Feed one SSE line; returns the text chunks to yield downstream.
    /// Reasoning is wrapped in the app-wide `<think>`…`</think>` convention so
    /// the UI and the reasoning-split accounting treat it like every other
    /// backend.
    mutating func handle(line: String, now: Date = Date()) -> [InferenceChunk] {
        guard line.hasPrefix("data: ") else { return [] }
        let json = String(line.dropFirst(6))
        guard let data = json.data(using: .utf8),
              let event = try? JSONDecoder().decode(Event.self, from: data) else {
            return []
        }

        switch event.type {
        case "reasoning.start":
            reasoningStart = reasoningStart ?? now
            return [InferenceChunk(text: "<think>", done: false)]
        case "reasoning.delta":
            reasoningPieces += 1
            reasoningEnd = now
            guard let content = event.content, !content.isEmpty else { return [] }
            return [InferenceChunk(text: content, done: false)]
        case "reasoning.end":
            reasoningEnd = now
            return [InferenceChunk(text: "</think>", done: false)]
        case "message.delta":
            outputPieces += 1
            guard let content = event.content, !content.isEmpty else { return [] }
            return [InferenceChunk(text: content, done: false)]
        case "model_load.end":
            loadTimeSeconds = event.loadTimeSeconds
            return []
        case "chat.end":
            sawChatEnd = true
            stats = event.result?.stats
            // Keep the raw stats object verbatim for the server-metrics UI.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let resultObj = obj["result"] as? [String: Any],
               let statsObj = resultObj["stats"] as? [String: Any],
               let statsData = try? JSONSerialization.data(withJSONObject: statsObj, options: [.sortedKeys]),
               let statsStr = String(data: statsData, encoding: .utf8) {
                rawStatsJSON = statsStr
            }
            return []
        default:
            // chat.start, model_load.start/progress, prompt_processing.*,
            // message.start/end, and anything future LM Studio adds.
            return []
        }
    }

    // MARK: - Finalization

    /// Build the terminal InferenceStats. `startTime` is the client-side
    /// request-dispatch stamp; totalDuration stays end-to-end wall time per
    /// methodology v3, while the throughput numbers come from the server.
    func finalize(startTime: Date, now: Date = Date()) -> InferenceStats {
        let wallTotal = now.timeIntervalSince(startTime)
        let load = stats?.modelLoadTimeSeconds ?? loadTimeSeconds ?? 0

        let completionToks = stats?.totalOutputTokens ?? (reasoningPieces + outputPieces)
        let promptToks = stats?.inputTokens ?? 0
        let reasoningToks = stats?.reasoningOutputTokens ?? (stats == nil ? reasoningPieces : 0)

        // The server reports rate + TTFT but no explicit decode duration —
        // derive it, so evalDuration stays consistent with the reported rate.
        let evalDuration: TimeInterval
        if let tps = stats?.tokensPerSecond, tps > 0, completionToks > 0 {
            evalDuration = Double(completionToks) / tps
        } else {
            // Stream died before chat.end — end-to-end wall time minus what
            // we can attribute elsewhere is the best available estimate.
            evalDuration = max(0, wallTotal - load - (stats?.timeToFirstTokenSeconds ?? 0))
        }

        let reasoningDuration: TimeInterval
        if let rs = reasoningStart {
            reasoningDuration = max(0, (reasoningEnd ?? now).timeIntervalSince(rs))
        } else {
            reasoningDuration = 0
        }

        return InferenceStats(
            totalTokens: promptToks + completionToks,
            promptTokens: promptToks,
            completionTokens: completionToks,
            totalDuration: wallTotal,
            // No separate prefill figure in v1 stats; server TTFT (which
            // excludes load) is the closest measure of prompt processing,
            // same proxy the oMLX chain uses.
            promptEvalDuration: stats?.timeToFirstTokenSeconds ?? 0,
            evalDuration: evalDuration,
            loadDuration: load,
            contextLength: promptToks > 0 ? promptToks + completionToks : 0,
            reasoningTokens: reasoningToks,
            reasoningDuration: reasoningDuration,
            reportedTokensPerSecond: stats?.tokensPerSecond,
            serverReportedTTFT: stats?.timeToFirstTokenSeconds,
            reportedPromptTokensPerSecond: nil,
            serverReportedMetricsJSON: rawStatsJSON
        )
    }
}

/// Request body for `POST /api/v1/chat`. LM Studio validates strictly and
/// rejects unrecognized keys, so only fields the API accepts are modeled.
/// Not supported by the endpoint (verified empirically): `seed`, `stop`.
struct LMStudioNativeChatRequest: Codable {
    let model: String
    let input: String
    let stream: Bool
    let systemPrompt: String?
    let maxOutputTokens: Int?
    let temperature: Double?
    let topP: Double?
    /// "on"/"off". Only send when the user explicitly toggled thinking —
    /// models without reasoning support reject the key with a 400.
    let reasoning: String?

    enum CodingKeys: String, CodingKey {
        case model, input, stream, temperature, reasoning
        case systemPrompt = "system_prompt"
        case maxOutputTokens = "max_output_tokens"
        case topP = "top_p"
    }
}
