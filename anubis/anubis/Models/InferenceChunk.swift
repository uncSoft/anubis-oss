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
        reasoningDuration: TimeInterval = 0
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
    }

    /// Output token count excluding reasoning/thinking tokens.
    var outputTokens: Int {
        max(0, completionTokens - reasoningTokens)
    }

    /// Generation duration excluding reasoning time. Used for output tok/s.
    var outputEvalDuration: TimeInterval {
        max(0, evalDuration - reasoningDuration)
    }

    /// Tokens per second for visible output (excludes thinking).
    var tokensPerSecond: Double {
        let dur = outputEvalDuration
        guard dur > 0 else { return 0 }
        return Double(outputTokens) / dur
    }

    /// Average latency per output token in milliseconds.
    var averageTokenLatencyMs: Double {
        let toks = outputTokens
        guard toks > 0 else { return 0 }
        return (outputEvalDuration * 1000) / Double(toks)
    }

    /// Prompt processing speed — input tokens/sec (prefill speed).
    var promptProcessingSpeed: Double {
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

    init(
        model: String,
        prompt: String,
        systemPrompt: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        stopSequences: [String]? = nil,
        ollamaThinkMode: OllamaThinkMode = .auto
    ) {
        self.model = model
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.stopSequences = stopSequences
        self.ollamaThinkMode = ollamaThinkMode
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
