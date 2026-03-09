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
            options: OllamaOptions(
                numPredict: request.maxTokens,
                temperature: request.temperature,
                topP: request.topP,
                stop: request.stopSequences
            )
        )

        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await session.bytes(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnubisError.invalidResponse(details: "Not an HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            throw AnubisError.invalidResponse(details: "Status \(httpResponse.statusCode)")
        }

        for try await line in bytes.lines {
            guard !line.isEmpty else { continue }

            guard let data = line.data(using: .utf8) else { continue }

            let chunk = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)

            let stats: InferenceStats? = chunk.done ? InferenceStats(
                totalTokens: (chunk.promptEvalCount ?? 0) + (chunk.evalCount ?? 0),
                promptTokens: chunk.promptEvalCount ?? 0,
                completionTokens: chunk.evalCount ?? 0,
                totalDuration: Double(chunk.totalDuration ?? 0) / 1_000_000_000,
                promptEvalDuration: Double(chunk.promptEvalDuration ?? 0) / 1_000_000_000,
                evalDuration: Double(chunk.evalDuration ?? 0) / 1_000_000_000,
                loadDuration: Double(chunk.loadDuration ?? 0) / 1_000_000_000,
                contextLength: chunk.context?.count ?? 0
            ) : nil

            continuation.yield(InferenceChunk(
                text: chunk.response,
                done: chunk.done,
                stats: stats
            ))

            if chunk.done {
                continuation.finish()
                return
            }
        }

        continuation.finish()
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

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnubisError.invalidResponse(details: "Not an HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            throw AnubisError.invalidResponse(details: "Status \(httpResponse.statusCode)")
        }

        for try await line in bytes.lines {
            guard !line.isEmpty else { continue }

            guard let data = line.data(using: .utf8) else { continue }

            let chunk = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)

            let stats: InferenceStats? = chunk.done ? InferenceStats(
                totalTokens: (chunk.promptEvalCount ?? 0) + (chunk.evalCount ?? 0),
                promptTokens: chunk.promptEvalCount ?? 0,
                completionTokens: chunk.evalCount ?? 0,
                totalDuration: Double(chunk.totalDuration ?? 0) / 1_000_000_000,
                promptEvalDuration: Double(chunk.promptEvalDuration ?? 0) / 1_000_000_000,
                evalDuration: Double(chunk.evalDuration ?? 0) / 1_000_000_000,
                loadDuration: Double(chunk.loadDuration ?? 0) / 1_000_000_000,
                contextLength: chunk.context?.count ?? 0
            ) : nil

            continuation.yield(InferenceChunk(
                text: chunk.response,
                done: chunk.done,
                stats: stats
            ))

            if chunk.done {
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
    let options: OllamaOptions?
}

private struct OllamaGenerateRequestFull: Codable {
    let model: String
    let prompt: String
    let system: String?
    let stream: Bool
    let keepAlive: String?
    let options: OllamaOptions?

    enum CodingKeys: String, CodingKey {
        case model, prompt, system, stream, options
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
