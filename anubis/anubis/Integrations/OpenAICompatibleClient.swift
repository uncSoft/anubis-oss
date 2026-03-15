//
//  OpenAICompatibleClient.swift
//  anubis
//
//  Created on 2026-01-26.
//

import Foundation

/// Client for OpenAI-compatible API endpoints (LM Studio, LocalAI, vLLM, etc.)
actor OpenAICompatibleClient: InferenceBackend {
    // MARK: - Properties

    let backendType: InferenceBackendType = .openai
    let configuration: BackendConfiguration

    private let baseURL: URL
    private let session: URLSession
    private let apiKey: String?

    // MARK: - Initialization

    init(configuration: BackendConfiguration) {
        self.configuration = configuration
        // Strip trailing /v1 or /v1/ — Anubis appends the versioned path automatically
        var url = Constants.URLs.parse(configuration.baseURL, fallback: Constants.URLs.openAIDefault)
        let pathSuffixes = ["/v1/", "/v1"]
        for suffix in pathSuffixes {
            if url.path.hasSuffix(suffix) {
                let trimmed = String(url.absoluteString.dropLast(suffix.count))
                if let fixed = URL(string: trimmed) { url = fixed }
                break
            }
        }
        self.baseURL = url
        self.apiKey = configuration.apiKey

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
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
        // Try to hit the models endpoint
        let url = baseURL.appendingPathComponent("v1/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .unhealthy(error: "Not an HTTP response")
            }

            if httpResponse.statusCode == 200 {
                return .healthy(version: nil)
            } else if httpResponse.statusCode == 401 {
                return .unhealthy(error: "Authentication required")
            } else {
                return .unhealthy(error: "Status \(httpResponse.statusCode)")
            }
        } catch {
            return .unhealthy(error: error.localizedDescription)
        }
    }

    func listModels() async throws -> [ModelInfo] {
        let url = baseURL.appendingPathComponent("v1/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnubisError.invalidResponse(details: "Not an HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            throw AnubisError.invalidResponse(details: "Status \(httpResponse.statusCode)")
        }

        let modelsResponse = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        let configId = configuration.id

        // Try to fetch richer metadata from LM Studio-style endpoint
        let richModels = await fetchLMStudioModels()

        // Scan known model directories once for disk enrichment
        let diskIndex = Self.indexModelDirectories()

        return modelsResponse.data.map { model in
            let parsed = Self.parseModelId(model.id)
            let diskMatch = Self.findDiskMatch(modelId: model.id, in: diskIndex)
            let richMatch = richModels?[model.id]

            return ModelInfo(
                id: model.id,
                name: model.id,
                family: parsed.family,
                parameterCount: richMatch?.parameterCount ?? parsed.parameterCount,
                quantization: richMatch?.quantization ?? diskMatch?.quantization ?? parsed.quantization,
                modelFormat: richMatch?.modelFormat ?? diskMatch?.modelFormat ?? parsed.modelFormat,
                sizeBytes: richMatch?.sizeBytes ?? diskMatch?.sizeBytes,
                contextLength: richMatch?.contextLength,
                backend: .openai,
                openAIConfigId: configId,
                path: diskMatch?.path,
                modifiedAt: diskMatch?.modifiedAt
            )
        }
    }

    /// Attempt to fetch rich model metadata from LM Studio's extended endpoint.
    /// Returns a dictionary keyed by model ID, or nil if the endpoint isn't available.
    private func fetchLMStudioModels() async -> [String: LMStudioModelMeta]? {
        let url = baseURL.appendingPathComponent("api/v1/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }

        guard let lmResponse = try? JSONDecoder().decode(LMStudioModelsResponse.self, from: data) else {
            return nil
        }

        var result: [String: LMStudioModelMeta] = [:]
        for model in lmResponse.models {
            let quantization = model.quantization?.name
            let modelFormat: ModelFormat? = {
                guard let fmt = model.format?.lowercased() else { return nil }
                if fmt == "gguf" { return .gguf }
                if fmt == "mlx" { return .mlx }
                return nil
            }()
            let parameterCount: Double? = {
                guard let ps = model.paramsString else { return nil }
                let lower = ps.lowercased()
                // Parse "9B", "1.2B", "70B", "200M" etc.
                if lower.hasSuffix("b"), let val = Double(lower.dropLast()) {
                    return val
                }
                if lower.hasSuffix("m"), let val = Double(lower.dropLast()) {
                    return val / 1000.0
                }
                return nil
            }()

            result[model.key] = LMStudioModelMeta(
                quantization: quantization,
                modelFormat: modelFormat,
                parameterCount: parameterCount,
                sizeBytes: model.sizeBytes,
                contextLength: model.maxContextLength
            )
        }
        return result
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
        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var messages: [[String: String]] = []
        if let systemPrompt = request.systemPrompt {
            messages.append(["role": "system", "content": systemPrompt])
        }
        messages.append(["role": "user", "content": request.prompt])

        let body = OpenAIChatRequest(
            model: request.model,
            messages: messages,
            stream: true,
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            topP: request.topP,
            stop: request.stopSequences
        )

        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await session.bytes(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnubisError.invalidResponse(details: "Not an HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            // Try to read error body for better diagnostics
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 500 { break } // Limit error body size
            }
            throw AnubisError.invalidResponse(details: "Status \(httpResponse.statusCode): \(errorBody)")
        }

        var totalTokens = 0
        let startTime = Date()
        var firstTokenTime: Date?
        var lastUsage: OpenAIUsage?

        for try await line in bytes.lines {
            // SSE format: "data: {...}" or "data: [DONE]"
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))

            if jsonString == "[DONE]" {
                let now = Date()
                let totalDuration = now.timeIntervalSince(startTime)
                let promptEval = firstTokenTime.map { $0.timeIntervalSince(startTime) } ?? 0
                let evalDuration = firstTokenTime.map { now.timeIntervalSince($0) } ?? totalDuration
                // Use backend-reported token counts when available, fall back to our approximation
                let promptToks = lastUsage?.promptTokens ?? 0
                let completionToks = lastUsage?.completionTokens ?? totalTokens
                let stats = InferenceStats(
                    totalTokens: promptToks + completionToks,
                    promptTokens: promptToks,
                    completionTokens: completionToks,
                    totalDuration: totalDuration,
                    promptEvalDuration: promptEval,
                    evalDuration: evalDuration,
                    loadDuration: 0,
                    contextLength: promptToks > 0 ? promptToks + completionToks : 0
                )
                continuation.yield(InferenceChunk(text: "", done: true, stats: stats))
                continuation.finish()
                return
            }

            guard let data = jsonString.data(using: .utf8) else { continue }

            do {
                let chunk = try JSONDecoder().decode(OpenAIChatStreamResponse.self, from: data)
                let content = chunk.choices.first?.delta.content

                // Capture usage if provided (typically on the final chunk)
                if let usage = chunk.usage {
                    lastUsage = usage
                }

                if let content = content, !content.isEmpty {
                    totalTokens += 1  // Approximate token count (used as fallback)
                    if firstTokenTime == nil {
                        firstTokenTime = Date()
                    }
                    continuation.yield(InferenceChunk(text: content, done: false, stats: nil))
                }

                // Check finish_reason - generation complete before [DONE]
                if let finishReason = chunk.choices.first?.finishReason,
                   finishReason == "stop" || finishReason == "length" {
                    let now = Date()
                    let totalDuration = now.timeIntervalSince(startTime)
                    let promptEval = firstTokenTime.map { $0.timeIntervalSince(startTime) } ?? 0
                    let evalDuration = firstTokenTime.map { now.timeIntervalSince($0) } ?? totalDuration
                    let promptToks = lastUsage?.promptTokens ?? 0
                    let completionToks = lastUsage?.completionTokens ?? totalTokens
                    let stats = InferenceStats(
                        totalTokens: promptToks + completionToks,
                        promptTokens: promptToks,
                        completionTokens: completionToks,
                        totalDuration: totalDuration,
                        promptEvalDuration: promptEval,
                        evalDuration: evalDuration,
                        loadDuration: 0,
                        contextLength: promptToks > 0 ? promptToks + completionToks : 0
                    )
                    continuation.yield(InferenceChunk(text: "", done: true, stats: stats))
                    continuation.finish()
                    return
                }
            } catch {
                // Skip malformed chunks
                continue
            }
        }

        continuation.finish()
    }
}

// MARK: - Model ID Parsing & Disk Enrichment

extension OpenAICompatibleClient {
    /// Metadata extracted from parsing a model ID string
    private struct ParsedModelId {
        let family: String?
        let parameterCount: Double?
        let quantization: String?
        let modelFormat: ModelFormat?
    }

    /// Metadata found on disk for a model
    private struct DiskModelEntry {
        let path: String
        let folderName: String       // Lowercased for matching
        let sizeBytes: Int64
        let quantization: String?
        let modelFormat: ModelFormat?
        let modifiedAt: Date?
    }

    /// Known family patterns: (keyword in model ID → family name)
    private static let familyPatterns: [(keyword: String, family: String)] = [
        ("llama", "llama"), ("mistral", "mistral"), ("ministral", "mistral"),
        ("qwen", "qwen"), ("phi", "phi"), ("gemma", "gemma"),
        ("deepseek", "deepseek"), ("yi-", "yi"), ("/yi", "yi"),
        ("falcon", "falcon"), ("mpt", "mpt"), ("starcoder", "starcoder"),
        ("codellama", "llama"), ("vicuna", "llama"), ("orca", "orca"),
        ("glm", "glm"), ("chatglm", "glm"), ("internlm", "internlm"),
        ("command", "command-r"), ("lfm", "lfm"), ("gpt-oss", "gpt"),
    ]

    /// Parse a model ID (e.g. "mistralai/ministral-3-3b") for metadata
    private nonisolated static func parseModelId(_ id: String) -> ParsedModelId {
        let lowerId = id.lowercased()

        // Family: check org prefix and model name against known patterns
        var family: String?
        for pattern in familyPatterns {
            if lowerId.contains(pattern.keyword) {
                family = pattern.family
                break
            }
        }

        // Parameter count: find last occurrence of (number)b pattern
        // Matches: "3b", "7b", "70b", "1.2b", "3-3b" (take the last number before b)
        var parameterCount: Double?
        if let regex = try? NSRegularExpression(pattern: #"(\d+\.?\d*)\s*[bB]\b"#),
           let match = regex.matches(in: id, range: NSRange(id.startIndex..., in: id)).last,
           let numRange = Range(match.range(at: 1), in: id) {
            parameterCount = Double(id[numRange])
        }

        // Quantization: rarely in API IDs, but check for common patterns
        var quantization: String?
        let quantPatterns = ["q4_k_m", "q4_k_s", "q5_k_m", "q5_k_s", "q6_k", "q8_0",
                             "q4_0", "q5_0", "q3_k", "fp16", "f16", "f32", "bf16"]
        for qp in quantPatterns {
            if lowerId.contains(qp) {
                quantization = qp.uppercased()
                break
            }
        }

        // Model format: detect from ID string
        var modelFormat: ModelFormat?
        if lowerId.contains("gguf") {
            modelFormat = .gguf
        } else if lowerId.contains("mlx") || lowerId.contains("safetensors") {
            modelFormat = .mlx
        }

        return ParsedModelId(family: family, parameterCount: parameterCount, quantization: quantization, modelFormat: modelFormat)
    }

    /// Known directories where model files may be stored
    private static var knownModelDirs: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.lmstudio/models",
            "\(home)/.cache/huggingface/hub",
        ]
    }

    /// Index model folders in known directories.
    /// Returns entries with folder name, size, quantization, and path.
    private nonisolated static func indexModelDirectories() -> [DiskModelEntry] {
        let fm = FileManager.default
        var entries: [DiskModelEntry] = []

        for baseDir in knownModelDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: baseDir, isDirectory: &isDir), isDir.boolValue else { continue }

            guard let orgDirs = try? fm.contentsOfDirectory(atPath: baseDir) else { continue }

            for orgDir in orgDirs {
                guard !orgDir.hasPrefix(".") else { continue }
                let orgPath = "\(baseDir)/\(orgDir)"
                guard fm.fileExists(atPath: orgPath, isDirectory: &isDir), isDir.boolValue else { continue }

                // HuggingFace hub uses flat "models--org--name" dirs
                if orgDir.hasPrefix("models--") {
                    let entry = buildEntry(dirPath: orgPath, folderName: orgDir, fm: fm)
                    if let entry { entries.append(entry) }
                    continue
                }

                // LM Studio / standard: org/model-folder structure
                guard let modelDirs = try? fm.contentsOfDirectory(atPath: orgPath) else { continue }
                for modelDir in modelDirs {
                    guard !modelDir.hasPrefix(".") else { continue }
                    let modelPath = "\(orgPath)/\(modelDir)"
                    guard fm.fileExists(atPath: modelPath, isDirectory: &isDir), isDir.boolValue else { continue }
                    let entry = buildEntry(dirPath: modelPath, folderName: modelDir, fm: fm)
                    if let entry { entries.append(entry) }
                }
            }
        }

        return entries
    }

    /// Build a DiskModelEntry for a model directory
    private nonisolated static func buildEntry(dirPath: String, folderName: String, fm: FileManager) -> DiskModelEntry? {
        let (size, modified) = directorySize(at: dirPath, fm: fm)
        guard size > 0 else { return nil }
        let quant = extractQuantization(from: folderName, dirPath: dirPath, fm: fm)
        let format = detectModelFormat(from: folderName, dirPath: dirPath, fm: fm)

        return DiskModelEntry(
            path: dirPath,
            folderName: folderName.lowercased(),
            sizeBytes: size,
            quantization: quant,
            modelFormat: format,
            modifiedAt: modified
        )
    }

    /// Compute total size of all files in a directory (non-recursive for speed, then check one level)
    private nonisolated static func directorySize(at path: String, fm: FileManager) -> (Int64, Date?) {
        guard let enumerator = fm.enumerator(atPath: path) else { return (0, nil) }
        var total: Int64 = 0
        var latestDate: Date?

        while let file = enumerator.nextObject() as? String {
            let filePath = "\(path)/\(file)"
            guard let attrs = try? fm.attributesOfItem(atPath: filePath) else { continue }
            if let fileType = attrs[.type] as? FileAttributeType, fileType == .typeRegular {
                total += (attrs[.size] as? Int64) ?? 0
            }
            if let modified = attrs[.modificationDate] as? Date {
                if latestDate == nil || modified > latestDate! {
                    latestDate = modified
                }
            }
        }

        return (total, latestDate)
    }

    /// Extract quantization from folder name or contained filenames
    private nonisolated static func extractQuantization(from folderName: String, dirPath: String, fm: FileManager) -> String? {
        let lower = folderName.lowercased()

        // Check folder name for common patterns
        // GGUF quant levels
        let ggufPatterns = ["q4_k_m", "q4_k_s", "q5_k_m", "q5_k_s", "q6_k", "q8_0",
                            "q4_0", "q5_0", "q3_k_s", "q3_k_m", "q3_k_l", "q2_k"]
        for pattern in ggufPatterns {
            if lower.contains(pattern) { return pattern.uppercased() }
        }

        // MLX quantization
        if lower.contains("mxfp4") { return "MXFP4" }
        if lower.contains("4bit") || lower.contains("4-bit") { return "4-bit" }
        if lower.contains("8bit") || lower.contains("8-bit") { return "8-bit" }
        if lower.contains("fp16") || lower.contains("f16") { return "FP16" }

        // Check GGUF filenames inside the directory for quant info
        if lower.contains("gguf") {
            if let files = try? fm.contentsOfDirectory(atPath: dirPath) {
                for file in files where file.hasSuffix(".gguf") && !file.hasPrefix("mmproj") {
                    let lowerFile = file.lowercased()
                    for pattern in ggufPatterns {
                        if lowerFile.contains(pattern) { return pattern.uppercased() }
                    }
                }
            }
        }

        return nil
    }

    /// Detect model format from folder name or contained files
    private nonisolated static func detectModelFormat(from folderName: String, dirPath: String, fm: FileManager) -> ModelFormat? {
        let lower = folderName.lowercased()

        // Check folder name
        if lower.contains("gguf") { return .gguf }
        if lower.contains("mlx") { return .mlx }

        // Check file extensions in directory
        if let files = try? fm.contentsOfDirectory(atPath: dirPath) {
            let hasGGUF = files.contains { $0.hasSuffix(".gguf") }
            let hasSafetensors = files.contains { $0.hasSuffix(".safetensors") }

            if hasGGUF { return .gguf }
            if hasSafetensors { return .mlx }
        }

        return nil
    }

    /// Find the best disk match for a model ID
    private nonisolated static func findDiskMatch(modelId: String, in index: [DiskModelEntry]) -> DiskModelEntry? {
        guard !index.isEmpty else { return nil }

        // Extract the model name part (after org/, or the whole thing)
        let parts = modelId.split(separator: "/")
        let modelName = parts.count > 1 ? String(parts.last!) : modelId
        let lowerName = modelName.lowercased()

        // Need at least 4 chars to avoid false positives
        guard lowerName.count >= 4 else { return nil }

        // Try exact substring match first (most reliable)
        var bestMatch: DiskModelEntry?
        var bestScore = 0

        for entry in index {
            if entry.folderName.contains(lowerName) {
                // Score by how closely the lengths match (prefer tighter matches)
                let score = lowerName.count * 100 / max(entry.folderName.count, 1)
                if score > bestScore {
                    bestScore = score
                    bestMatch = entry
                }
            }
        }

        if bestMatch != nil { return bestMatch }

        // Fallback: try matching with dashes/dots normalized
        let normalizedName = lowerName.replacingOccurrences(of: ".", with: "-")
        for entry in index {
            let normalizedFolder = entry.folderName.replacingOccurrences(of: ".", with: "-")
            if normalizedFolder.contains(normalizedName) {
                return entry
            }
        }

        return nil
    }
}

// MARK: - OpenAI API Types

private struct OpenAIModelsResponse: Codable {
    let data: [OpenAIModel]
}

private struct OpenAIModel: Codable {
    let id: String
    let object: String?
    let created: Int?
    let ownedBy: String?

    enum CodingKeys: String, CodingKey {
        case id, object, created
        case ownedBy = "owned_by"
    }
}

private struct OpenAIChatRequest: Codable {
    let model: String
    let messages: [[String: String]]
    let stream: Bool
    let maxTokens: Int?
    let temperature: Double?
    let topP: Double?
    let stop: [String]?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, stop
        case maxTokens = "max_tokens"
        case topP = "top_p"
    }
}

private struct OpenAIChatStreamResponse: Codable {
    let id: String?
    let object: String?
    let created: Int?
    let model: String?
    let choices: [OpenAIStreamChoice]
    let usage: OpenAIUsage?
}

private struct OpenAIUsage: Codable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

private struct OpenAIStreamChoice: Codable {
    let index: Int?
    let delta: OpenAIDelta
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index, delta
        case finishReason = "finish_reason"
    }
}

private struct OpenAIDelta: Codable {
    let role: String?
    let content: String?
}

// MARK: - LM Studio Extended API Types

/// Rich metadata extracted from LM Studio's /api/v1/models/ endpoint
private struct LMStudioModelMeta {
    let quantization: String?
    let modelFormat: ModelFormat?
    let parameterCount: Double?
    let sizeBytes: Int64?
    let contextLength: Int?
}

private struct LMStudioModelsResponse: Codable {
    let models: [LMStudioModel]
}

private struct LMStudioModel: Codable {
    let key: String
    let quantization: LMStudioQuantization?
    let format: String?
    let paramsString: String?
    let sizeBytes: Int64?
    let maxContextLength: Int?

    enum CodingKeys: String, CodingKey {
        case key, quantization, format
        case paramsString = "params_string"
        case sizeBytes = "size_bytes"
        case maxContextLength = "max_context_length"
    }
}

private struct LMStudioQuantization: Codable {
    let name: String
    let bitsPerWeight: Double?

    enum CodingKeys: String, CodingKey {
        case name
        case bitsPerWeight = "bits_per_weight"
    }
}
