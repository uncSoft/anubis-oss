//
//  InferenceChunk.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation

/// A chunk of streaming inference output
struct InferenceChunk: Sendable {
    /// The generated text fragment
    let text: String

    /// Whether this is the final chunk
    let done: Bool

    /// Token generation statistics (available when done)
    let stats: InferenceStats?

    /// Timestamp when this chunk was received
    let timestamp: Date

    init(text: String, done: Bool = false, stats: InferenceStats? = nil) {
        self.text = text
        self.done = done
        self.stats = stats
        self.timestamp = Date()
    }
}

/// Statistics from an inference run
struct InferenceStats: Sendable, Codable {
    /// Total tokens generated
    let totalTokens: Int

    /// Tokens in the prompt
    let promptTokens: Int

    /// Tokens generated in the response
    let completionTokens: Int

    /// Total time for inference in seconds
    let totalDuration: TimeInterval

    /// Time to process the prompt in seconds
    let promptEvalDuration: TimeInterval

    /// Time to generate tokens in seconds. For reasoning models, this covers
    /// the full generation phase including thinking — `outputEvalDuration`
    /// excludes thinking and is what should be used for output tk/s.
    let evalDuration: TimeInterval

    /// Time to load the model in seconds (cold start indicator)
    let loadDuration: TimeInterval

    /// Number of context tokens used
    let contextLength: Int

    /// Tokens emitted as reasoning/thinking (subset of completionTokens). 0 if not a reasoning run.
    let reasoningTokens: Int

    /// Time spent producing reasoning tokens in seconds. 0 if not a reasoning run.
    let reasoningDuration: TimeInterval

    /// Backend-reported generation throughput (tok/s), when the server measures
    /// it itself inside the decode loop (oMLX). Preferred over our wall-clock
    /// derivation, which a bursty SSE reader can inflate wildly (issue #25).
    /// nil for backends that report only token counts (mlx-lm, LM Studio, ...).
    let reportedTokensPerSecond: Double?

    /// Backend-reported time-to-first-token in seconds (oMLX). nil otherwise,
    /// in which case the ViewModel uses its own first-chunk wall-clock timing.
    let serverReportedTTFT: TimeInterval?

    /// Backend-reported prompt (prefill) throughput in tok/s (oMLX). Preferred
    /// over deriving prompt_tokens / prompt_eval_duration, which rounds slightly
    /// differently from the backend's own figure. nil for other servers.
    let reportedPromptTokensPerSecond: Double?

    /// The backend's raw `usage` object as a JSON string, captured verbatim
    /// when it reports its own metrics (oMLX). Lets the UI display every field
    /// exactly as the server sent it, including ones we don't model. nil
    /// for backends that report only standard token counts.
    let serverReportedMetricsJSON: String?

    init(
        totalTokens: Int,
        promptTokens: Int,
        completionTokens: Int,
        totalDuration: TimeInterval,
        promptEvalDuration: TimeInterval,
        evalDuration: TimeInterval,
        loadDuration: TimeInterval,
        contextLength: Int,
        reasoningTokens: Int = 0,
        reasoningDuration: TimeInterval = 0,
        reportedTokensPerSecond: Double? = nil,
        serverReportedTTFT: TimeInterval? = nil,
        reportedPromptTokensPerSecond: Double? = nil,
        serverReportedMetricsJSON: String? = nil
    ) {
        self.totalTokens = totalTokens
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalDuration = totalDuration
        self.promptEvalDuration = promptEvalDuration
        self.evalDuration = evalDuration
        self.loadDuration = loadDuration
        self.contextLength = contextLength
        self.reasoningTokens = reasoningTokens
        self.reasoningDuration = reasoningDuration
        self.reportedTokensPerSecond = reportedTokensPerSecond
        self.serverReportedTTFT = serverReportedTTFT
        self.reportedPromptTokensPerSecond = reportedPromptTokensPerSecond
        self.serverReportedMetricsJSON = serverReportedMetricsJSON
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.totalTokens = try c.decode(Int.self, forKey: .totalTokens)
        self.promptTokens = try c.decode(Int.self, forKey: .promptTokens)
        self.completionTokens = try c.decode(Int.self, forKey: .completionTokens)
        self.totalDuration = try c.decode(TimeInterval.self, forKey: .totalDuration)
        self.promptEvalDuration = try c.decode(TimeInterval.self, forKey: .promptEvalDuration)
        self.evalDuration = try c.decode(TimeInterval.self, forKey: .evalDuration)
        self.loadDuration = try c.decode(TimeInterval.self, forKey: .loadDuration)
        self.contextLength = try c.decode(Int.self, forKey: .contextLength)
        self.reasoningTokens = (try? c.decode(Int.self, forKey: .reasoningTokens)) ?? 0
        self.reasoningDuration = (try? c.decode(TimeInterval.self, forKey: .reasoningDuration)) ?? 0
        self.reportedTokensPerSecond = try? c.decode(Double.self, forKey: .reportedTokensPerSecond)
        self.serverReportedTTFT = try? c.decode(TimeInterval.self, forKey: .serverReportedTTFT)
        self.reportedPromptTokensPerSecond = try? c.decode(Double.self, forKey: .reportedPromptTokensPerSecond)
        self.serverReportedMetricsJSON = try? c.decode(String.self, forKey: .serverReportedMetricsJSON)
    }

    /// Output token count excluding reasoning/thinking tokens.
    var outputTokens: Int {
        max(0, completionTokens - reasoningTokens)
    }

    /// Generation duration excluding reasoning time. Used for output tok/s.
    var outputEvalDuration: TimeInterval {
        max(0, evalDuration - reasoningDuration)
    }

    /// Decode throughput over ALL generated tokens (reasoning included),
    /// matching the convention every other tool uses: Ollama's `eval rate`
    /// (`eval_count / eval_duration`), llama.cpp's `predicted_per_second`,
    /// and llmperf/genai-perf output throughput. Reasoning tokens are decoded
    /// at the same hardware speed as visible ones, so they belong in the rate.
    ///
    /// The previous "visible output only" variant — (completion − reasoning) /
    /// (eval − reasoningDuration) — divided two small differences of
    /// independently-estimated quantities. When a model spent nearly its whole
    /// token budget thinking, the denominator collapsed and the leaderboard
    /// received rows claiming 5,000–29,000 tok/s. Use
    /// `reasoningTokensPerSecond` for the thinking-phase rate instead.
    var tokensPerSecond: Double {
        // Trust the backend's own decode-loop measurement when it provides one
        // (oMLX, llama.cpp timings). It can't be corrupted by client-side read
        // bursts the way our wall-clock derivation can (issue #25).
        if let reported = reportedTokensPerSecond, reported > 0 {
            return reported
        }
        if completionTokens > 0 && evalDuration > 0 {
            return Double(completionTokens) / evalDuration
        }
        return 0
    }

    /// True when stream timing suggests the backend buffered the entire
    /// response and emitted it in a burst at the end rather than streaming
    /// incrementally. In that case `evalDuration` measures the burst-decode
    /// window, not the real generation time, and `tokensPerSecond` based on
    /// it will be implausibly high. UI should annotate, not override.
    var hasSuspiciousStreamTiming: Bool {
        // Timing measured inside the backend's decode loop can't be
        // corrupted by client-side read bursts — a genuinely fast small
        // model shouldn't be flagged.
        reportedTokensPerSecond == nil
            && completionTokens > 100 && evalDuration > 0 && evalDuration < 1.0
    }

    /// Average latency per generated token in milliseconds (TPOT). Defined as
    /// the exact reciprocal of `tokensPerSecond` so the two can never disagree
    /// — including when the backend reports its own throughput (oMLX,
    /// llama.cpp), which the old formula ignored.
    ///
    /// `nil` (rather than 0) when no tokens were generated: the metric is
    /// undefined then, and writing 0 would silently bias downstream
    /// aggregates / leaderboard averages toward 0. See GitHub issue #30.
    var averageTokenLatencyMs: Double? {
        let tps = tokensPerSecond
        guard tps > 0 else { return nil }
        return 1000 / tps
    }

    /// Prompt processing speed — input tokens/sec (prefill speed).
    var promptProcessingSpeed: Double {
        // Trust the backend's own prefill rate when it reports one (oMLX).
        if let reported = reportedPromptTokensPerSecond, reported > 0 {
            return reported
        }
        guard promptEvalDuration > 0 else { return 0 }
        return Double(promptTokens) / promptEvalDuration
    }

    /// Reasoning/thinking generation speed (tokens/sec).
    var reasoningTokensPerSecond: Double {
        guard reasoningDuration > 0 else { return 0 }
        return Double(reasoningTokens) / reasoningDuration
    }
}

/// Request configuration for inference
/// Controls Ollama's `think` request parameter for reasoning-capable models.
/// `auto` omits the field entirely so the model uses its server-side default
/// (the safe choice — older Ollama versions and non-thinking models reject
/// the parameter outright). `on`/`off` force `think:true` / `think:false`.
enum OllamaThinkMode: String, Sendable, Codable, CaseIterable {
    case auto
    case on
    case off

    var displayLabel: String {
        switch self {
        case .auto: return "Auto"
        case .on:   return "On"
        case .off:  return "Off"
        }
    }
}

struct InferenceRequest: Sendable {
    /// The model to use
    let model: String

    /// The prompt text
    let prompt: String

    /// System prompt (optional)
    let systemPrompt: String?

    /// Maximum tokens to generate
    let maxTokens: Int?

    /// Temperature for sampling (0.0 - 2.0)
    let temperature: Double?

    /// Top-p sampling parameter
    let topP: Double?

    /// Stop sequences
    let stopSequences: [String]?

    /// Ollama-only: control the `think` request parameter. Ignored by other backends.
    let ollamaThinkMode: OllamaThinkMode

    /// Optional sampler seed. When set, both Ollama and OpenAI-compatible
    /// backends are asked to use it for reproducible sampling. Used by
    /// run groups: random seeds per rep (default) capture sampler noise
    /// in the bootstrap CI; a fixed seed across reps isolates hardware
    /// variance only.
    let seed: Int64?

    init(
        model: String,
        prompt: String,
        systemPrompt: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        stopSequences: [String]? = nil,
        ollamaThinkMode: OllamaThinkMode = .auto,
        seed: Int64? = nil
    ) {
        self.model = model
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.stopSequences = stopSequences
        self.ollamaThinkMode = ollamaThinkMode
        self.seed = seed
    }
}

/// Response from a complete inference run
struct InferenceResponse: Sendable {
    /// The complete generated text
    let text: String

    /// Statistics from the run
    let stats: InferenceStats

    /// The model used
    let model: String

    /// Backend that processed the request
    let backend: InferenceBackendType
}
