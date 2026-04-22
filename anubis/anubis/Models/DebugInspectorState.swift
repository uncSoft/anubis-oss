//
//  DebugInspectorState.swift
//  anubis
//
//  Created on 2026-01-28.
//

import Foundation

/// Tracks per-request lifecycle state for the debug inspector
struct DebugInspectorState {
    // MARK: - Phase

    enum Phase: String {
        case idle = "Idle"
        case connecting = "Connecting"
        case streaming = "Streaming"
        case complete = "Complete"
        case error = "Error"
    }

    // MARK: - Request Info

    var backendType: InferenceBackendType?
    var endpointURL: String?
    var modelId: String?
    var requestTimestamp: Date?
    var promptSnippet: String?
    var systemPrompt: String?
    var maxTokens: Int?
    var temperature: Double?
    var topP: Double?

    // MARK: - Live Status

    var phase: Phase = .idle
    var chunksReceived: Int = 0
    var bytesReceived: Int = 0
    var firstChunkAt: Date?
    var lastChunkAt: Date?

    // MARK: - Completion

    var completedAt: Date?
    var finalTokensPerSecond: Double?
    var finalTotalTokens: Int?
    var errorMessage: String?

    // MARK: - Reconstructed Request

    var requestJSON: String?

    // MARK: - Computed Properties

    /// Elapsed time since request started
    var elapsed: TimeInterval? {
        guard let start = requestTimestamp else { return nil }
        let end = completedAt ?? Date()
        return end.timeIntervalSince(start)
    }

    /// Time to first chunk in milliseconds
    var timeToFirstChunkMs: Double? {
        guard let start = requestTimestamp, let first = firstChunkAt else { return nil }
        return first.timeIntervalSince(start) * 1000
    }

    /// Chunks received per second
    var chunksPerSecond: Double? {
        guard let elapsed = elapsed, elapsed > 0, chunksReceived > 0 else { return nil }
        return Double(chunksReceived) / elapsed
    }

    // MARK: - Mutation

    mutating func reset() {
        self = DebugInspectorState()
    }

    // MARK: - Request JSON Builder

    /// Reconstructs the JSON body that the backend would receive
    static func buildRequestJSON(
        backend: InferenceBackendType,
        model: String,
        prompt: String,
        systemPrompt: String?,
        maxTokens: Int?,
        temperature: Double?,
        topP: Double?
    ) -> String {
        switch backend {
        case .ollama:
            return buildOllamaJSON(
                model: model, prompt: prompt, systemPrompt: systemPrompt,
                maxTokens: maxTokens, temperature: temperature, topP: topP
            )
        case .openai:
            return buildOpenAIJSON(
                model: model, prompt: prompt, systemPrompt: systemPrompt,
                maxTokens: maxTokens, temperature: temperature, topP: topP
            )
        case .appleIntelligence:
            return buildAppleIntelligenceSummary(
                prompt: prompt, systemPrompt: systemPrompt,
                maxTokens: maxTokens, temperature: temperature
            )
        }
    }

    private static func buildAppleIntelligenceSummary(
        prompt: String,
        systemPrompt: String?,
        maxTokens: Int?,
        temperature: Double?
    ) -> String {
        var dict: [String: Any] = [
            "framework": "FoundationModels.LanguageModelSession",
            "prompt": prompt
        ]
        if let sys = systemPrompt, !sys.isEmpty {
            dict["instructions"] = sys
        }
        var options: [String: Any] = [:]
        if let temp = temperature { options["temperature"] = temp }
        if let max = maxTokens { options["maximumResponseTokens"] = max }
        if !options.isEmpty { dict["options"] = options }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "{}"
    }

    private static func buildOllamaJSON(
        model: String,
        prompt: String,
        systemPrompt: String?,
        maxTokens: Int?,
        temperature: Double?,
        topP: Double?
    ) -> String {
        var dict: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": true
        ]
        if let sys = systemPrompt, !sys.isEmpty {
            dict["system"] = sys
        }
        var options: [String: Any] = [:]
        if let mt = maxTokens { options["num_predict"] = mt }
        if let t = temperature { options["temperature"] = t }
        if let tp = topP { options["top_p"] = tp }
        if !options.isEmpty {
            dict["options"] = options
        }
        return prettyJSON(dict)
    }

    private static func buildOpenAIJSON(
        model: String,
        prompt: String,
        systemPrompt: String?,
        maxTokens: Int?,
        temperature: Double?,
        topP: Double?
    ) -> String {
        var messages: [[String: String]] = []
        if let sys = systemPrompt, !sys.isEmpty {
            messages.append(["role": "system", "content": sys])
        }
        messages.append(["role": "user", "content": prompt])

        var dict: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true
        ]
        if let mt = maxTokens { dict["max_tokens"] = mt }
        if let t = temperature { dict["temperature"] = t }
        if let tp = topP { dict["top_p"] = tp }
        return prettyJSON(dict)
    }

    private static func prettyJSON(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
