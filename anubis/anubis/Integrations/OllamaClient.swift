//
//  OllamaClient.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation

/// Client for interacting with the Ollama REST API
actor OllamaClient: InferenceBackend {
    // MARK: - Properties

    let backendType: InferenceBackendType = .ollama

    private let baseURL: URL
    private let session: URLSession

    // MARK: - Initialization

    init(baseURL: URL = Constants.URLs.ollamaDefault) {
        self.baseURL = baseURL

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300 // 5 minutes for long generations
        config.timeoutIntervalForResource = 600 // 10 minutes total
        self.session = URLSession(configuration: config)
    }

    // MARK: - InferenceBackend

    var isAvailable: Bool {
        get async {
            let health = await checkHealth()
            return health.isRunning
        }
    }

    func checkHealth() async -> BackendHealth {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return .unhealthy(error: "Ollama returned non-200 status")
            }
            return .healthy(version: nil)
        } catch {
            return .unhealthy(error: error.localizedDescription)
        }
    }

    func listModels() async throws -> [ModelInfo] {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnubisError.invalidResponse(details: "Not an HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            throw AnubisError.backendNotRunning(backend: "Ollama")
        }

        let tagsResponse = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return tagsResponse.models.map { model in
            ModelInfo(
                id: model.name,
                name: model.name,
                family: model.details?.family,
                parameterCount: parseParameterCount(model.details?.parameterSize),
                quantization: model.details?.quantizationLevel,
                modelFormat: .gguf,
                sizeBytes: model.size,
                contextLength: nil,
                backend: .ollama,
                openAIConfigId: nil,
                path: nil,
                modifiedAt: parseDate(model.modifiedAt)
            )
        }
    }

    func generate(request: InferenceRequest) -> AsyncThrowingStream<InferenceChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await streamGenerate(request: request, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private Methods

    private func streamGenerate(
        request: InferenceRequest,
        continuation: AsyncThrowingStream<InferenceChunk, Error>.Continuation
    ) async throws {
        let url = baseURL.appendingPathComponent("api/generate")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = OllamaGenerateRequest(
            model: request.model,
            prompt: request.prompt,
            system: request.systemPrompt,
            stream: true,
            think: Self.thinkValue(for: request.ollamaThinkMode),
            options: OllamaOptions(
                numPredict: request.maxTokens,
                temperature: request.temperature,
                topP: request.topP,
                stop: request.stopSequences
            )
        )

        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await session.bytes(for: urlRequest)

        try await Self.consumeOllamaStream(
            bytes: bytes,
            response: response,
            continuation: continuation
        )
    }

    private func parseParameterCount(_ size: String?) -> Double? {
        guard let size = size else { return nil }
        let lowercased = size.lowercased()
        if lowercased.hasSuffix("b") {
            return Double(lowercased.dropLast())
        } else if lowercased.hasSuffix("m") {
            if let value = Double(lowercased.dropLast()) {
                return value / 1000
            }
        }
        return nil
    }

    private func parseDate(_ dateString: String?) -> Date? {
        guard let dateString = dateString else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: dateString)
    }

    // MARK: - Model Management

    /// List currently loaded/running models
    func listRunningModels() async throws -> [RunningModel] {
        let url = baseURL.appendingPathComponent("api/ps")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AnubisError.invalidResponse(details: "Failed to list running models")
        }

        let psResponse = try JSONDecoder().decode(OllamaPsResponse.self, from: data)
        return psResponse.models.map { model in
            RunningModel(
                name: model.name,
                sizeBytes: model.size,
                sizeVRAM: model.sizeVram,
                expiresAt: parseDate(model.expiresAt)
            )
        }
    }

    /// Unload a model from memory
    func unloadModel(_ name: String) async throws {
        let url = baseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Send empty generate with keep_alive: 0 to unload
        let body: [String: Any] = [
            "model": name,
            "prompt": "",
            "keep_alive": 0
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AnubisError.invalidResponse(details: "Failed to unload model")
        }
    }

    /// Generate with custom keep_alive setting
    func generate(request: InferenceRequest, keepAlive: String? = nil) -> AsyncThrowingStream<InferenceChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await streamGenerate(request: request, keepAlive: keepAlive, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func streamGenerate(
        request: InferenceRequest,
        keepAlive: String?,
        continuation: AsyncThrowingStream<InferenceChunk, Error>.Continuation
    ) async throws {
        let url = baseURL.appendingPathComponent("api/generate")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = OllamaGenerateRequestFull(
            model: request.model,
            prompt: request.prompt,
            system: request.systemPrompt,
            stream: true,
            think: Self.thinkValue(for: request.ollamaThinkMode),
            keepAlive: keepAlive,
            options: OllamaOptions(
                numPredict: request.maxTokens,
                temperature: request.temperature,
                topP: request.topP,
                stop: request.stopSequences
            )
        )

        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await session.bytes(for: urlRequest)

        try await Self.consumeOllamaStream(
            bytes: bytes,
            response: response,
            continuation: continuation
        )
    }

    /// Map the user-facing think mode to the JSON value to send (or omit).
    /// `.auto` → nil (field omitted from request); `.on`/`.off` → explicit bool.
    private static func thinkValue(for mode: OllamaThinkMode) -> Bool? {
        switch mode {
        case .auto: return nil
        case .on:   return true
        case .off:  return false
        }
    }

    /// Pull a quoted model id out of an Ollama JSON error body, e.g.
    /// `{"error":"\"llama3.2:3b\" does not support thinking"}` → `llama3.2:3b`.
    /// Falls back to nil if the shape doesn't match — the caller will use a
    /// generic "this model" placeholder.
    private static func extractQuotedModelId(from body: String) -> String? {
        // First try to JSON-decode the body to get the unescaped error string.
        // Ollama always returns {"error": "..."} on this path.
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = obj["error"] as? String {
            // Now msg looks like:  "llama3.2:3b" does not support thinking
            if let openQuote = msg.firstIndex(of: "\""),
               let closeQuote = msg[msg.index(after: openQuote)...].firstIndex(of: "\"") {
                return String(msg[msg.index(after: openQuote)..<closeQuote])
            }
        }
        return nil
    }

    /// Shared stream-consumption logic. Splits inline `<think>…</think>` blocks
    /// in Ollama's `response` field into reasoning vs. output, decodes the
    /// optional `thinking` field for Ollama 0.5+ servers, and surfaces clear
    /// errors with the response body when the request fails.
    private static func consumeOllamaStream(
        bytes: URLSession.AsyncBytes,
        response: URLResponse,
        continuation: AsyncThrowingStream<InferenceChunk, Error>.Continuation
    ) async throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnubisError.invalidResponse(details: "Not an HTTP response")
        }

        if httpResponse.statusCode != 200 {
            // Drain the body so we can report Ollama's actual error message
            // (rather than a bare status code) — useful for "model does not
            // support thinking", "model not loaded", malformed prompt, etc.
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 1000 { break }
            }
            #if DEBUG
            print("[Ollama] HTTP \(httpResponse.statusCode) error body: \(errorBody)")
            #endif

            // Detect the specific "does not support thinking" 400 so we can
            // surface a friendlier, actionable error pointing at the toggle.
            // Ollama's body looks like: {"error":"\"llama3.2:3b\" does not support thinking"}
            if httpResponse.statusCode == 400,
               errorBody.contains("does not support thinking") {
                let modelId = Self.extractQuotedModelId(from: errorBody)
                throw AnubisError.thinkingNotSupported(modelId: modelId ?? "this model")
            }

            throw AnubisError.invalidResponse(
                details: "Ollama returned HTTP \(httpResponse.statusCode)\(errorBody.isEmpty ? "" : ": \(errorBody)")"
            )
        }

        var thinkingState = OllamaThinkingState()
        let decoder = JSONDecoder()

        for try await line in bytes.lines {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8) else { continue }

            let chunk: OllamaGenerateResponse
            do {
                chunk = try decoder.decode(OllamaGenerateResponse.self, from: data)
            } catch {
                #if DEBUG
                print("[Ollama] failed to decode line: \(line)")
                print("[Ollama] decode error: \(error)")
                #endif
                throw AnubisError.streamingError(
                    reason: "Could not parse Ollama response: \(error.localizedDescription)"
                )
            }

            // Decode any `thinking` field (Ollama 0.5+ when supported).
            thinkingState.observe(chunk: chunk) { piece in
                continuation.yield(piece)
            }

            // Split inline <think>…</think> tags in the response body so models
            // that emit thinking inline are also accounted for.
            let pieces = thinkingState.processInlineResponse(chunk.response)
            for piece in pieces {
                continuation.yield(InferenceChunk(text: piece, done: false))
            }

            let stats: InferenceStats? = chunk.done ? thinkingState.stats(from: chunk) : nil
            if chunk.done {
                continuation.yield(InferenceChunk(text: "", done: true, stats: stats))
                continuation.finish()
                return
            }
        }

        continuation.finish()
    }

    // MARK: - Model Information

    /// Get detailed information about a model
    func showModelInfo(_ name: String) async throws -> OllamaModelInfo {
        let url = baseURL.appendingPathComponent("api/show")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["name": name])

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AnubisError.modelLoadFailed(modelId: name, reason: "Failed to get model info")
        }

        return try JSONDecoder().decode(OllamaModelInfo.self, from: data)
    }

    /// Delete a model
    func deleteModel(_ name: String) async throws {
        let url = baseURL.appendingPathComponent("api/delete")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["name": name])

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AnubisError.modelLoadFailed(modelId: name, reason: "Failed to delete model")
        }
    }

    /// Pull (download) a model with progress updates
    func pullModel(_ name: String) -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await streamPull(name: name, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func streamPull(
        name: String,
        continuation: AsyncThrowingStream<PullProgress, Error>.Continuation
    ) async throws {
        let url = baseURL.appendingPathComponent("api/pull")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3600 // 1 hour for large models
        let body = OllamaPullRequest(name: name, stream: true)
        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AnubisError.modelLoadFailed(modelId: name, reason: "Failed to start pull")
        }

        for try await line in bytes.lines {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }

            let pullResponse = try JSONDecoder().decode(OllamaPullResponse.self, from: data)

            let progress = PullProgress(
                status: pullResponse.status,
                digest: pullResponse.digest,
                total: pullResponse.total,
                completed: pullResponse.completed
            )

            continuation.yield(progress)

            if pullResponse.status == "success" {
                continuation.finish()
                return
            }
        }

        continuation.finish()
    }
}

/// A currently loaded model
struct RunningModel: Identifiable {
    var id: String { name }
    let name: String
    let sizeBytes: Int64
    let sizeVRAM: Int64
    let expiresAt: Date?

    var isExpiringSoon: Bool {
        guard let expires = expiresAt else { return false }
        return expires.timeIntervalSinceNow < 60 // Less than 1 minute
    }
}

/// Progress update during model pull
struct PullProgress: Sendable {
    let status: String
    let digest: String?
    let total: Int64?
    let completed: Int64?

    var percentComplete: Double? {
        guard let total = total, let completed = completed, total > 0 else { return nil }
        return Double(completed) / Double(total)
    }

    var isDownloading: Bool {
        status.contains("pulling") || status.contains("downloading")
    }
}

/// Detailed model information from /api/show
struct OllamaModelInfo: Codable {
    let modelfile: String?
    let parameters: String?
    let template: String?
    let details: OllamaShowDetails?
    let modelInfo: [String: AnyCodableValue]?

    enum CodingKeys: String, CodingKey {
        case modelfile, parameters, template, details
        case modelInfo = "model_info"
    }

    // Convenience accessors for common model_info fields
    var architecture: String? {
        modelInfo?["general.architecture"]?.stringValue
    }

    var parameterCount: Int64? {
        modelInfo?["general.parameter_count"]?.int64Value
    }

    var contextLength: Int? {
        modelInfo?["llama.context_length"]?.intValue
            ?? modelInfo?["mistral.context_length"]?.intValue
            ?? modelInfo?["qwen2.context_length"]?.intValue
    }

    var embeddingLength: Int? {
        modelInfo?["llama.embedding_length"]?.intValue
            ?? modelInfo?["mistral.embedding_length"]?.intValue
    }

    var blockCount: Int? {
        modelInfo?["llama.block_count"]?.intValue
            ?? modelInfo?["mistral.block_count"]?.intValue
    }

    var headCount: Int? {
        modelInfo?["llama.attention.head_count"]?.intValue
    }

    var kvHeadCount: Int? {
        modelInfo?["llama.attention.head_count_kv"]?.intValue
    }

    var vocabSize: Int? {
        modelInfo?["llama.vocab_size"]?.intValue
    }

    var ropeFreqBase: Double? {
        modelInfo?["llama.rope.freq_base"]?.doubleValue
    }
}

struct OllamaShowDetails: Codable {
    let parentModel: String?
    let format: String?
    let family: String?
    let families: [String]?
    let parameterSize: String?
    let quantizationLevel: String?

    enum CodingKeys: String, CodingKey {
        case parentModel = "parent_model"
        case format, family, families
        case parameterSize = "parameter_size"
        case quantizationLevel = "quantization_level"
    }
}

/// Type-erased codable value for dynamic JSON
enum AnyCodableValue: Codable {
    case string(String)
    case int(Int)
    case int64(Int64)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int64(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .int64(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .int64(let value): return Int(value)
        case .double(let value): return Int(value)
        default: return nil
        }
    }

    var int64Value: Int64? {
        switch self {
        case .int(let value): return Int64(value)
        case .int64(let value): return value
        case .double(let value): return Int64(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .int64(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }
}

// MARK: - Ollama API Types

private struct OllamaTagsResponse: Codable {
    let models: [OllamaModel]
}

private struct OllamaModel: Codable {
    let name: String
    let size: Int64?
    let modifiedAt: String?
    let details: OllamaModelDetails?

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case modifiedAt = "modified_at"
        case details
    }
}

private struct OllamaModelDetails: Codable {
    let family: String?
    let parameterSize: String?
    let quantizationLevel: String?

    enum CodingKeys: String, CodingKey {
        case family
        case parameterSize = "parameter_size"
        case quantizationLevel = "quantization_level"
    }
}

private struct OllamaGenerateRequest: Codable {
    let model: String
    let prompt: String
    let system: String?
    let stream: Bool
    /// Ollama 0.5+: enables separate `thinking` field on streamed responses for
    /// reasoning-capable models. Servers that don't recognize the field ignore it.
    let think: Bool?
    let options: OllamaOptions?
}

private struct OllamaGenerateRequestFull: Codable {
    let model: String
    let prompt: String
    let system: String?
    let stream: Bool
    let think: Bool?
    let keepAlive: String?
    let options: OllamaOptions?

    enum CodingKeys: String, CodingKey {
        case model, prompt, system, stream, think, options
        case keepAlive = "keep_alive"
    }
}

private struct OllamaPsResponse: Codable {
    let models: [OllamaRunningModel]
}

private struct OllamaRunningModel: Codable {
    let name: String
    let size: Int64
    let sizeVram: Int64
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case name, size
        case sizeVram = "size_vram"
        case expiresAt = "expires_at"
    }
}

private struct OllamaOptions: Codable {
    let numPredict: Int?
    let temperature: Double?
    let topP: Double?
    let stop: [String]?

    enum CodingKeys: String, CodingKey {
        case numPredict = "num_predict"
        case temperature
        case topP = "top_p"
        case stop
    }
}

private struct OllamaGenerateResponse: Codable {
    let model: String
    let response: String
    /// Ollama 0.5+ streams reasoning content here separately when `think: true`.
    let thinking: String?
    let done: Bool
    let context: [Int]?
    let totalDuration: Int64?
    let loadDuration: Int64?
    let promptEvalCount: Int?
    let promptEvalDuration: Int64?
    let evalCount: Int?
    let evalDuration: Int64?

    enum CodingKeys: String, CodingKey {
        case model
        case response
        case thinking
        case done
        case context
        case totalDuration = "total_duration"
        case loadDuration = "load_duration"
        case promptEvalCount = "prompt_eval_count"
        case promptEvalDuration = "prompt_eval_duration"
        case evalCount = "eval_count"
        case evalDuration = "eval_duration"
    }
}

/// Tracks reasoning chunks so we can wrap them visibly and split eval
/// duration / completion tokens into thinking vs. output halves. Handles
/// both Ollama 0.5+ `thinking` field and inline `<think>…</think>` blocks.
private struct OllamaThinkingState {
    private var reasoningStartedAt: Date?
    private var reasoningEndedAt: Date?
    private var firstResponseAt: Date?
    /// Reasoning chunk count (from `thinking` field OR text inside `<think>` tags).
    private var reasoningChunkCount = 0
    /// Output chunk count (visible response excluding reasoning).
    private var responseChunkCount = 0

    /// True while we're inside an inline <think> block in the response stream.
    private var insideInlineThink = false
    /// Buffer for partial inline <think>/</think> tags spanning chunk boundaries.
    private var pendingTagBuffer = ""

    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    /// Decode the dedicated `thinking` field (Ollama 0.5+ servers).
    /// Yields `<think>…</think>` markers around the streamed reasoning text.
    mutating func observe(chunk: OllamaGenerateResponse, yield: (InferenceChunk) -> Void) {
        let now = Date()

        if let thinking = chunk.thinking, !thinking.isEmpty {
            if reasoningStartedAt == nil {
                reasoningStartedAt = now
                yield(InferenceChunk(text: "<think>", done: false))
            }
            reasoningEndedAt = now
            reasoningChunkCount += 1
            yield(InferenceChunk(text: thinking, done: false))
        }

        if !chunk.response.isEmpty {
            // First non-thinking output: close the explicit-field reasoning marker
            // if we opened one. Inline <think> handling is separate.
            if firstResponseAt == nil {
                firstResponseAt = now
                if reasoningStartedAt != nil && !insideInlineThink {
                    yield(InferenceChunk(text: "</think>", done: false))
                }
            }
        } else if chunk.done && reasoningStartedAt != nil && firstResponseAt == nil && !insideInlineThink {
            yield(InferenceChunk(text: "</think>", done: false))
        }
    }

    /// Split the `response` field on inline `<think>…</think>` tags. Tags
    /// straddling chunk boundaries are buffered. Pieces are returned ready
    /// to yield as visible text — markers stay in the stream.
    mutating func processInlineResponse(_ chunk: String) -> [String] {
        guard !chunk.isEmpty else { return [] }
        var pieces: [String] = []
        var work = pendingTagBuffer + chunk
        pendingTagBuffer = ""

        while !work.isEmpty {
            let target = insideInlineThink ? Self.closeTag : Self.openTag
            if let range = work.range(of: target) {
                let before = String(work[..<range.lowerBound])
                if !before.isEmpty {
                    countToken(insideInlineThink, now: Date())
                    pieces.append(before)
                }
                pieces.append(target)
                if !insideInlineThink {
                    if reasoningStartedAt == nil { reasoningStartedAt = Date() }
                } else {
                    reasoningEndedAt = Date()
                }
                insideInlineThink.toggle()
                work = String(work[range.upperBound...])
            } else if let suffixIdx = Self.partialTagSuffix(work, target: target) {
                let safe = String(work[..<suffixIdx])
                if !safe.isEmpty {
                    countToken(insideInlineThink, now: Date())
                    pieces.append(safe)
                }
                pendingTagBuffer = String(work[suffixIdx...])
                break
            } else {
                countToken(insideInlineThink, now: Date())
                pieces.append(work)
                break
            }
        }
        return pieces
    }

    private mutating func countToken(_ asReasoning: Bool, now: Date) {
        if asReasoning {
            reasoningChunkCount += 1
        } else {
            if firstResponseAt == nil { firstResponseAt = now }
            responseChunkCount += 1
        }
    }

    private static func partialTagSuffix(_ s: String, target: String) -> String.Index? {
        let maxLen = min(s.count, target.count - 1)
        guard maxLen > 0 else { return nil }
        for len in stride(from: maxLen, through: 1, by: -1) {
            let suffix = s.suffix(len)
            if target.hasPrefix(suffix) {
                return s.index(s.endIndex, offsetBy: -len)
            }
        }
        return nil
    }

    /// Build InferenceStats from the final chunk, splitting eval_duration/eval_count
    /// across thinking and output proportionally to our local chunk counts.
    func stats(from chunk: OllamaGenerateResponse) -> InferenceStats {
        let totalEvalCount = chunk.evalCount ?? 0
        let totalEvalDurationS = Double(chunk.evalDuration ?? 0) / 1_000_000_000

        let chunkTotal = reasoningChunkCount + responseChunkCount
        let reasoningRatio: Double = chunkTotal > 0
            ? Double(reasoningChunkCount) / Double(chunkTotal)
            : 0

        // Prefer wall-clock reasoning duration when available; otherwise fall back
        // to the proportional split of eval_duration.
        let reasoningDuration: TimeInterval = {
            if let s = reasoningStartedAt {
                let e = firstResponseAt ?? reasoningEndedAt ?? s
                return max(0, e.timeIntervalSince(s))
            }
            return totalEvalDurationS * reasoningRatio
        }()

        let reasoningTokens = Int((Double(totalEvalCount) * reasoningRatio).rounded())

        return InferenceStats(
            totalTokens: (chunk.promptEvalCount ?? 0) + totalEvalCount,
            promptTokens: chunk.promptEvalCount ?? 0,
            completionTokens: totalEvalCount,
            totalDuration: Double(chunk.totalDuration ?? 0) / 1_000_000_000,
            promptEvalDuration: Double(chunk.promptEvalDuration ?? 0) / 1_000_000_000,
            evalDuration: totalEvalDurationS,
            loadDuration: Double(chunk.loadDuration ?? 0) / 1_000_000_000,
            contextLength: chunk.context?.count ?? 0,
            reasoningTokens: min(totalEvalCount, reasoningTokens),
            reasoningDuration: min(totalEvalDurationS, reasoningDuration)
        )
    }
}

private struct OllamaPullRequest: Codable {
    let name: String
    let stream: Bool
}

private struct OllamaPullResponse: Codable {
    let status: String
    let digest: String?
    let total: Int64?
    let completed: Int64?
}
