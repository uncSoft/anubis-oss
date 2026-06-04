//
//  OpenAICompatibleClient.swift
//  anubis
//
//  Created on 2026-01-26.
//

import Foundation

/// Errors from oMLX's admin API, derived from the server's `detail` message so
/// callers can distinguish a benign "not loaded" from a genuine failure.
enum OMLXAdminError: LocalizedError, Sendable {
    case modelNotLoaded(detail: String)
    case modelNotFound(detail: String)
    case requestFailed(detail: String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "This model isn't loaded, so there's nothing to unload."
        case .modelNotFound:  return "This model wasn't found on the oMLX server."
        case .requestFailed(let detail): return detail
        }
    }

    /// True when the request "failed" only because the model wasn't loaded —
    /// the caller can treat this as a no-op success for an unload action.
    var isBenignNotLoaded: Bool {
        if case .modelNotLoaded = self { return true }
        return false
    }
}

/// A HuggingFace model surfaced by oMLX's model browser (search/recommended).
struct OMLXHFModel: Sendable, Identifiable {
    var id: String { repoId }
    let repoId: String
    let name: String
    let downloads: Int
    let likes: Int
    let sizeBytes: Int64
    let sizeFormatted: String
    let paramsFormatted: String?
}

/// A HuggingFace download task from oMLX (`/admin/api/hf/tasks`).
struct OMLXHFTask: Sendable {
    let taskId: String
    let repoId: String
    let status: String      // pending | downloading | completed | failed | cancelled
    let progress: Double    // 0–100
    let totalSize: Int64
    let downloadedSize: Int64
    let error: String
    let createdAt: Double
}

/// A model entry from oMLX's admin API (`/admin/api/models`), carrying loaded
/// state and real memory size. Surfaced in the Vault / Benchmark UI for
/// oMLX model management (load / unload).
struct OMLXManagedModel: Sendable, Identifiable {
    let id: String
    let loaded: Bool
    let isLoading: Bool
    let sizeBytes: Int64?
    let sizeFormatted: String?
    let pinned: Bool
    let isDefault: Bool
}

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
        // Force IPv4 for localhost. macOS resolves "localhost" to ::1 first,
        // but local inference servers (oMLX, LM Studio, mlx-lm, vLLM) bind
        // 127.0.0.1 only — so the IPv6 attempt is refused and we'd rely on a
        // flaky Happy-Eyeballs fallback (which the admin/HF calls don't get).
        if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           comps.host == "localhost" {
            comps.host = "127.0.0.1"
            if let fixed = comps.url { url = fixed }
        }
        self.baseURL = url
        self.apiKey = configuration.apiKey

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        // Optimize delivery path for streaming chat completions —
        // URLSession buffers less aggressively in this mode, so SSE
        // chunks land in the async iterator the moment they arrive
        // rather than being batched into 16KB+ flushes.
        config.networkServiceType = .responsiveData
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
                modifiedAt: diskMatch?.modifiedAt,
                ownedBy: model.ownedBy
            )
        }
    }

    // MARK: - oMLX Admin API (model management)
    //
    // oMLX exposes load/unload + loaded-state under /admin/api, gated by a
    // session cookie obtained via /admin/api/login using the SAME api_key the
    // user configured for inference. URLSessionConfiguration.default stores the
    // cookie in shared storage and auto-attaches it to subsequent /admin calls.
    // These endpoints exist only on oMLX; callers gate by oMLX identity.

    /// Extract a human message from an OpenAI-style error body
    /// (`{"error":{"message":"..."}}`) or a plain `{"detail":"..."}`.
    private static func openAIErrorMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
            return msg
        }
        if let detail = obj["detail"] as? String { return detail }
        return nil
    }

    /// Log in to oMLX's admin API with the configured API key. The
    /// `omlx_admin_session` cookie is stored on this session for reuse.
    @discardableResult
    func adminLogin() async -> Bool {
        guard let apiKey = apiKey, !apiKey.isEmpty else { return false }
        let url = baseURL.appendingPathComponent("admin/api/login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["api_key": apiKey, "remember": true]
        )
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return false
        }
        return true
    }

    /// List oMLX's managed models with loaded state + sizes. Logs in on demand.
    func managedModels() async throws -> [OMLXManagedModel] {
        let data = try await adminRequest("admin/api/models", method: "GET")
        let decoded = try JSONDecoder().decode(OMLXAdminModelsResponse.self, from: data)
        return decoded.models.map { m in
            OMLXManagedModel(
                id: m.id,
                loaded: m.loaded ?? false,
                isLoading: m.isLoading ?? false,
                sizeBytes: m.actualSize ?? m.estimatedSize,
                sizeFormatted: m.actualSizeFormatted ?? m.estimatedSizeFormatted,
                pinned: m.pinned ?? false,
                isDefault: m.isDefault ?? false
            )
        }
    }

    /// Unload a model from oMLX's memory.
    func unloadModel(_ id: String) async throws {
        _ = try await adminRequest("admin/api/models/\(id)/unload", method: "POST", encodeComponent: id)
    }

    /// Load a model into oMLX's memory.
    func loadModel(_ id: String) async throws {
        _ = try await adminRequest("admin/api/models/\(id)/load", method: "POST", encodeComponent: id)
    }

    // MARK: - oMLX HuggingFace model browser/downloader

    /// Curated/trending MLX models from oMLX's HF integration.
    func hfRecommended(mlxOnly: Bool = true, limit: Int = 40) async throws -> [OMLXHFModel] {
        let data = try await adminRequest("admin/api/hf/recommended", method: "GET", query: [
            URLQueryItem(name: "mlx_only", value: mlxOnly ? "true" : "false"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ])
        // Recommended returns {trending: [...], popular: [...]}; tolerate
        // {models: [...]} and a bare array too. Merge, trending first, deduped.
        if let resp = try? JSONDecoder().decode(HFRecommendedResponse.self, from: data) {
            let combined = (resp.trending ?? []) + (resp.popular ?? []) + (resp.models ?? [])
            if !combined.isEmpty {
                var seen = Set<String>()
                return combined.compactMap { seen.insert($0.repoId).inserted ? $0.model : nil }
            }
        }
        return (try JSONDecoder().decode([HFModelDTO].self, from: data)).map(\.model)
    }

    /// Search HuggingFace for MLX models via oMLX.
    func hfSearch(query: String, mlxOnly: Bool = true, limit: Int = 40) async throws -> [OMLXHFModel] {
        let data = try await adminRequest("admin/api/hf/search", method: "GET", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "mlx_only", value: mlxOnly ? "true" : "false"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ])
        return (try JSONDecoder().decode(HFSearchResponse.self, from: data)).models.map(\.model)
    }

    /// Start a HuggingFace download. Progress is polled via `hfTasks()`.
    func hfDownload(repoId: String) async throws {
        _ = try await adminRequest("admin/api/hf/download", method: "POST", jsonBody: ["repo_id": repoId])
    }

    /// Current download tasks (poll for progress).
    func hfTasks() async throws -> [OMLXHFTask] {
        let data = try await adminRequest("admin/api/hf/tasks", method: "GET")
        return (try JSONDecoder().decode(HFTasksResponse.self, from: data)).tasks.map(\.task)
    }

    /// Cancel an in-flight download task.
    func hfCancel(_ taskId: String) async throws {
        _ = try await adminRequest("admin/api/hf/cancel/\(taskId)", method: "POST", encodeComponent: taskId)
    }

    /// Issue an authenticated admin request, logging in + retrying once on 401.
    /// `encodeComponent`, when set, is percent-encoded inside the path so model
    /// ids with reserved characters resolve correctly.
    private func adminRequest(
        _ path: String,
        method: String,
        query: [URLQueryItem]? = nil,
        encodeComponent: String? = nil,
        jsonBody: [String: Any]? = nil
    ) async throws -> Data {
        func makeURL() -> URL {
            var base: URL
            if let comp = encodeComponent {
                // Build the path safely around the single dynamic component.
                let encoded = comp.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? comp
                base = baseURL.appendingPathComponent(path.replacingOccurrences(of: comp, with: encoded))
            } else {
                base = baseURL.appendingPathComponent(path)
            }
            if let query = query,
               var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) {
                comps.queryItems = query
                return comps.url ?? base
            }
            return base
        }
        func makeRequest() -> URLRequest {
            var r = URLRequest(url: makeURL())
            r.httpMethod = method
            r.timeoutInterval = 30
            if let apiKey = apiKey, !apiKey.isEmpty {
                r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            if let jsonBody = jsonBody {
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = try? JSONSerialization.data(withJSONObject: jsonBody)
            }
            return r
        }

        var (data, response) = try await session.data(for: makeRequest())
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            // Session cookie missing/expired — authenticate and retry once.
            _ = await adminLogin()
            (data, response) = try await session.data(for: makeRequest())
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            // oMLX reports a JSON {"detail": "..."} — surface it so we can tell
            // "Model not loaded" (benign) apart from a real failure.
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            if let detail = detail {
                let lower = detail.lowercased()
                if code == 400, lower.contains("not loaded") {
                    throw OMLXAdminError.modelNotLoaded(detail: detail)
                }
                if code == 404, lower.contains("not found") {
                    throw OMLXAdminError.modelNotFound(detail: detail)
                }
                throw OMLXAdminError.requestFailed(detail: detail)
            }
            throw OMLXAdminError.requestFailed(detail: "oMLX admin request failed (HTTP \(code)).")
        }
        return data
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
        // Force plain (uncompressed) responses — URLSession buffers
        // bytes to gunzip gzipped streams, which produces visible
        // bursts of streamed SSE chunks. Plain text streams through.
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        // NOTE: do NOT set Connection: close here. LM Studio (and
        // probably other OpenAI-compatible servers built on
        // llama.cpp/vLLM) fails every other request in an N-rep group
        // when the previous request closed the TCP connection — the
        // server is still in teardown when we try to reconnect ~30 ms
        // later and rejects with a fast HTTP error. Ollama has the
        // opposite preference (Connection: close fixes chunk pacing
        // there) — so the header lives on OllamaClient instead.

        if let apiKey = apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var messages: [[String: String]] = []
        if let systemPrompt = request.systemPrompt {
            messages.append(["role": "system", "content": systemPrompt])
        }
        messages.append(["role": "user", "content": request.prompt])

        // Translate the thinking toggle into chat_template_kwargs (oMLX/vLLM).
        // Only sent when explicitly On/Off; Auto omits it so servers that don't
        // understand the field are unaffected.
        let templateKwargs: [String: Bool]?
        switch request.ollamaThinkMode {
        case .auto: templateKwargs = nil
        case .on:   templateKwargs = ["enable_thinking": true, "preserve_thinking": false]
        case .off:  templateKwargs = ["enable_thinking": false, "preserve_thinking": false]
        }

        let body = OpenAIChatRequest(
            model: request.model,
            messages: messages,
            stream: true,
            // Ask the server to include token counts in the final stream
            // chunk — LM Studio, vLLM, llama.cpp-server, etc. omit `usage`
            // unless this flag is set, which leaves promptTokens unknown.
            streamOptions: OpenAIStreamOptions(includeUsage: true),
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            topP: request.topP,
            stop: request.stopSequences,
            seed: request.seed,
            chatTemplateKwargs: templateKwargs
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
                if errorBody.count > 800 { break } // Limit error body size
            }
            // Surface the server's own message (OpenAI envelope: {"error":{"message":...}}).
            let serverMsg = Self.openAIErrorMessage(from: errorBody)
            let code = httpResponse.statusCode
            if code >= 500 {
                // A 500 on /v1/chat/completions almost always means the server
                // couldn't run this model — common with non-chat models
                // (vision/embedding) or experimental quants. Say so plainly.
                let detail = serverMsg.map { " (\($0))" } ?? ""
                throw AnubisError.backendMessage(
                    "The server failed to generate with this model (HTTP \(code))\(detail). "
                    + "It may not be a chat-capable model — some MLX models are vision, "
                    + "embedding, or experimental-quant builds that this server can't run for chat."
                )
            }
            throw AnubisError.backendMessage(serverMsg ?? "Request failed (HTTP \(code)).")
        }

        var state = StreamState()
        let startTime = Date()
        var lastUsage: OpenAIUsage?
        // Raw usage object exactly as the backend sent it, captured only when
        // it carries oMLX's extended timing. Persisted so the UI can show
        // oMLX's numbers verbatim, including any fields we don't model yet.
        var lastUsageRawJSON: String?
        var finalized = false

        // Emit the terminal chunk exactly once. Used by both the [DONE]
        // sentinel and the stream-closed fallback below.
        func emitFinal() {
            guard !finalized else { return }
            finalized = true
            let stats = state.finalize(startTime: startTime, usage: lastUsage, rawUsageJSON: lastUsageRawJSON)
            continuation.yield(InferenceChunk(text: "", done: true, stats: stats))
            continuation.finish()
        }

        for try await line in bytes.lines {
            // SSE format: "data: {...}" or "data: [DONE]"
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))

            if jsonString == "[DONE]" {
                emitFinal()
                return
            }

            guard let data = jsonString.data(using: .utf8) else { continue }

            do {
                let chunk = try JSONDecoder().decode(OpenAIChatStreamResponse.self, from: data)

                // Capture usage if provided (typically on the final chunk)
                if let usage = chunk.usage {
                    lastUsage = usage
                    // For oMLX (the only backend that reports its own timing),
                    // keep the raw usage object verbatim so we never lose or
                    // round a field — including ones we don't decode.
                    if usage.hasServerTiming,
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let usageObj = obj["usage"] as? [String: Any],
                       let usageData = try? JSONSerialization.data(withJSONObject: usageObj, options: [.sortedKeys]),
                       let usageStr = String(data: usageData, encoding: .utf8) {
                        lastUsageRawJSON = usageStr
                    }
                }

                let delta = chunk.choices.first?.delta

                // Reasoning streamed in a dedicated field (DeepSeek/Qwen/etc convention).
                // Yield wrapped in <think>…</think> so it's visible but distinguishable from output.
                if let rc = delta?.reasoningContent ?? delta?.reasoning, !rc.isEmpty {
                    let now = Date()
                    state.markFirstChunk(now)
                    if !state.reasoningOpen {
                        state.reasoningOpen = true
                        state.reasoningStart = now
                        continuation.yield(InferenceChunk(text: "<think>", done: false))
                    }
                    state.reasoningTokens += 1
                    state.reasoningEnd = now
                    continuation.yield(InferenceChunk(text: rc, done: false))
                }

                // Standard content. May contain inline <think>…</think> blocks (some
                // llama-cpp/lmstudio configurations emit reasoning this way).
                if let content = delta?.content, !content.isEmpty {
                    let pieces = state.processContent(content)
                    for piece in pieces {
                        let now = Date()
                        state.markFirstChunk(now)
                        switch piece.kind {
                        case .reasoning:
                            if !state.reasoningOpen {
                                state.reasoningOpen = true
                                state.reasoningStart = now
                            }
                            state.reasoningTokens += 1
                            state.reasoningEnd = now
                            continuation.yield(InferenceChunk(text: piece.text, done: false))
                        case .output:
                            // Close any reasoning emitted via the `reasoning_content` field
                            // before the first real output token.
                            if state.reasoningOpen && !state.reasoningClosedEmitted {
                                state.reasoningClosedEmitted = true
                                continuation.yield(InferenceChunk(text: "</think>", done: false))
                            }
                            if state.firstContentTime == nil {
                                state.firstContentTime = now
                            }
                            state.outputTokens += 1
                            continuation.yield(InferenceChunk(text: piece.text, done: false))
                        }
                    }
                }

                // Check finish_reason - generation is complete. Do NOT finalize
                // here: with stream_options.include_usage the server sends a
                // trailing usage-only chunk (choices: []) AFTER this one, and
                // oMLX packs its decode-loop timing into that block. Returning
                // now would drop it and fall back to wall-clock timing. Keep
                // reading; finalize on [DONE] or when the stream closes.
                if let finishReason = chunk.choices.first?.finishReason,
                   finishReason == "stop" || finishReason == "length" {
                    if state.reasoningOpen && !state.reasoningClosedEmitted {
                        state.reasoningClosedEmitted = true
                        continuation.yield(InferenceChunk(text: "</think>", done: false))
                    }
                }
            } catch {
                // Skip malformed chunks
                continue
            }
        }

        // Stream closed without a [DONE] sentinel (some servers omit it).
        // Finalize with whatever usage we captured.
        emitFinal()
    }
}

// MARK: - Stream State for Reasoning-Aware Parsing

/// Tracks reasoning vs. output tokens during a streaming chat completion.
/// Splits inline <think>…</think> blocks across chunks and surfaces the
/// timing needed for accurate prefill TPS, thinking TPS, and output TPS.
private struct StreamState {
    enum PieceKind { case reasoning, output }
    struct Piece { let kind: PieceKind; let text: String }

    var firstChunkTime: Date?
    var firstContentTime: Date?
    var reasoningStart: Date?
    var reasoningEnd: Date?

    var reasoningTokens = 0
    var outputTokens = 0

    var reasoningOpen = false
    var reasoningClosedEmitted = false

    /// True while we're inside an inline `<think>` block in the content stream.
    private var insideThinkTag = false
    /// Buffer for partial tags spanning chunk boundaries (e.g. "<thi" then "nk>").
    private var pendingTagBuffer = ""

    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    mutating func markFirstChunk(_ now: Date) {
        if firstChunkTime == nil { firstChunkTime = now }
    }

    /// Split a content delta into reasoning vs. output pieces, accounting for
    /// `<think>` tags that may straddle chunks.
    mutating func processContent(_ chunk: String) -> [Piece] {
        var pieces: [Piece] = []
        var work = pendingTagBuffer + chunk
        pendingTagBuffer = ""

        while !work.isEmpty {
            let target = insideThinkTag ? Self.closeTag : Self.openTag
            if let range = work.range(of: target) {
                let before = String(work[..<range.lowerBound])
                if !before.isEmpty {
                    pieces.append(Piece(kind: insideThinkTag ? .reasoning : .output, text: before))
                }
                // Emit the tag itself with the corresponding kind so users see the marker.
                pieces.append(Piece(kind: insideThinkTag ? .reasoning : .reasoning, text: target))
                insideThinkTag.toggle()
                work = String(work[range.upperBound...])
            } else {
                // Check whether the tail might be the start of a partial tag — defer it.
                if let suffixIdx = Self.partialTagSuffix(work, target: target) {
                    let safe = String(work[..<suffixIdx])
                    if !safe.isEmpty {
                        pieces.append(Piece(kind: insideThinkTag ? .reasoning : .output, text: safe))
                    }
                    pendingTagBuffer = String(work[suffixIdx...])
                } else {
                    pieces.append(Piece(kind: insideThinkTag ? .reasoning : .output, text: work))
                }
                break
            }
        }
        return pieces
    }

    /// Returns the start index of a possible partial-tag suffix in `s`, or nil.
    private static func partialTagSuffix(_ s: String, target: String) -> String.Index? {
        // Find the longest suffix of `s` that is a prefix of `target` (and < target.count).
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

    func finalize(startTime: Date, usage: OpenAIUsage?, rawUsageJSON: String? = nil) -> InferenceStats {
        let now = Date()
        let wallTotal = now.timeIntervalSince(startTime)

        // Prefer the backend's own timing when it reports it (oMLX). These are
        // measured inside the decode loop, so they're immune to the client-read
        // bursts that make wall-clock evalDuration collapse toward zero and
        // tok/s explode (issue #25). Fall back to wall-clock for plain mlx-lm,
        // LM Studio, vLLM, llama.cpp, etc. which report only token counts.
        let serverTiming = usage?.hasServerTiming ?? false

        let totalDuration = usage?.totalTime ?? wallTotal
        let promptEval = usage?.promptEvalDuration
            ?? usage?.timeToFirstToken
            ?? firstChunkTime.map { $0.timeIntervalSince(startTime) }
            ?? 0
        let evalDuration = usage?.generationDuration
            ?? firstChunkTime.map { now.timeIntervalSince($0) }
            ?? wallTotal

        // Reasoning duration: from first reasoning chunk to first content chunk
        // (or to end, if reasoning ran to completion without follow-on content).
        let reasoningDuration: TimeInterval
        if let rs = reasoningStart {
            let rEnd = firstContentTime ?? reasoningEnd ?? now
            reasoningDuration = max(0, rEnd.timeIntervalSince(rs))
        } else {
            reasoningDuration = 0
        }

        // Prefer backend-reported counts. If usage gives a single completion count
        // it includes reasoning — we approximate the split using our local counts.
        let promptToks = usage?.promptTokens ?? 0
        let backendCompletion = usage?.completionTokens
        let localCompletion = reasoningTokens + outputTokens
        let completionToks = backendCompletion ?? localCompletion

        // If backend total doesn't match our split, scale the local reasoning ratio.
        let reasoningTokenCount: Int = {
            guard reasoningTokens > 0 else { return 0 }
            if let backend = backendCompletion, localCompletion > 0 {
                let ratio = Double(reasoningTokens) / Double(localCompletion)
                return min(backend, Int((Double(backend) * ratio).rounded()))
            }
            return reasoningTokens
        }()

        return InferenceStats(
            totalTokens: promptToks + completionToks,
            promptTokens: promptToks,
            completionTokens: completionToks,
            totalDuration: totalDuration,
            promptEvalDuration: promptEval,
            evalDuration: evalDuration,
            loadDuration: usage?.modelLoadDuration ?? 0,
            contextLength: promptToks > 0 ? promptToks + completionToks : 0,
            reasoningTokens: reasoningTokenCount,
            reasoningDuration: reasoningDuration,
            // oMLX hands us the exact decode-loop throughput and TTFT; use them
            // verbatim so our headline numbers match the backend's own. nil for
            // every other server, which leaves tok/s/TTFT derived as before.
            reportedTokensPerSecond: serverTiming ? usage?.generationTokensPerSecond : nil,
            serverReportedTTFT: serverTiming ? (usage?.timeToFirstToken ?? usage?.promptEvalDuration) : nil,
            reportedPromptTokensPerSecond: serverTiming ? usage?.promptTokensPerSecond : nil,
            serverReportedMetricsJSON: serverTiming ? rawUsageJSON : nil
        )
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

// MARK: - oMLX Admin Models decode

private struct HFSearchResponse: Codable { let models: [HFModelDTO] }
private struct HFTasksResponse: Codable { let tasks: [HFTaskDTO] }
private struct HFRecommendedResponse: Codable {
    let trending: [HFModelDTO]?
    let popular: [HFModelDTO]?
    let models: [HFModelDTO]?
}

private struct HFModelDTO: Codable {
    let repoId: String
    let name: String?
    let downloads: Int?
    let likes: Int?
    let size: Int64?
    let sizeFormatted: String?
    let paramsFormatted: String?

    enum CodingKeys: String, CodingKey {
        case repoId = "repo_id"
        case name, downloads, likes, size
        case sizeFormatted = "size_formatted"
        case paramsFormatted = "params_formatted"
    }

    var model: OMLXHFModel {
        OMLXHFModel(
            repoId: repoId,
            name: name ?? repoId,
            downloads: downloads ?? 0,
            likes: likes ?? 0,
            sizeBytes: size ?? 0,
            sizeFormatted: sizeFormatted ?? "",
            paramsFormatted: paramsFormatted
        )
    }
}

private struct HFTaskDTO: Codable {
    let taskId: String
    let repoId: String?
    let status: String?
    let progress: Double?
    let totalSize: Int64?
    let downloadedSize: Int64?
    let error: String?
    let createdAt: Double?

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case repoId = "repo_id"
        case status, progress, error
        case totalSize = "total_size"
        case downloadedSize = "downloaded_size"
        case createdAt = "created_at"
    }

    var task: OMLXHFTask {
        OMLXHFTask(
            taskId: taskId,
            repoId: repoId ?? "",
            status: status ?? "",
            progress: progress ?? 0,
            totalSize: totalSize ?? 0,
            downloadedSize: downloadedSize ?? 0,
            error: error ?? "",
            createdAt: createdAt ?? 0
        )
    }
}

private struct OMLXAdminModelsResponse: Codable {
    let models: [OMLXAdminModel]
}

private struct OMLXAdminModel: Codable {
    let id: String
    let loaded: Bool?
    let isLoading: Bool?
    let actualSize: Int64?
    let estimatedSize: Int64?
    let actualSizeFormatted: String?
    let estimatedSizeFormatted: String?
    let pinned: Bool?
    let isDefault: Bool?

    enum CodingKeys: String, CodingKey {
        case id, loaded, pinned
        case isLoading = "is_loading"
        case actualSize = "actual_size"
        case estimatedSize = "estimated_size"
        case actualSizeFormatted = "actual_size_formatted"
        case estimatedSizeFormatted = "estimated_size_formatted"
        case isDefault = "is_default"
    }
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
    let streamOptions: OpenAIStreamOptions?
    let maxTokens: Int?
    let temperature: Double?
    let topP: Double?
    let stop: [String]?
    let seed: Int64?
    /// Passed to the model's chat template. oMLX (and vLLM) read
    /// `enable_thinking` here to toggle a reasoning model's chain-of-thought.
    /// Omitted (nil) unless the user explicitly set thinking On/Off.
    let chatTemplateKwargs: [String: Bool]?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, stop, seed
        case streamOptions = "stream_options"
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case chatTemplateKwargs = "chat_template_kwargs"
    }
}

private struct OpenAIStreamOptions: Codable {
    let includeUsage: Bool

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
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

    // --- oMLX extension (github.com/jundot/omlx) ---
    // oMLX reports authoritative timing in its usage object, measured
    // inside the decode loop and immune to client-side read stalls. When
    // present we trust these over wall-clock inference (which a bursty SSE
    // reader can corrupt into implausibly high tok/s -- see issue #25).
    // Values are seconds except the per-second rates. Plain mlx-lm, LM
    // Studio, vLLM, etc. omit them and we fall back to wall-clock timing.
    let timeToFirstToken: Double?
    let promptEvalDuration: Double?
    let generationDuration: Double?
    let promptTokensPerSecond: Double?
    let generationTokensPerSecond: Double?
    let modelLoadDuration: Double?
    let totalTime: Double?
    let promptTokensDetails: PromptTokensDetails?

    struct PromptTokensDetails: Codable {
        let cachedTokens: Int?
        enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
        }
    }

    /// True when the server supplied its own generation timing -- i.e. this
    /// is an oMLX-style backend and we should trust its numbers rather than
    /// inferring from chunk-arrival wall-clock.
    var hasServerTiming: Bool {
        generationDuration != nil || generationTokensPerSecond != nil
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case timeToFirstToken = "time_to_first_token"
        case promptEvalDuration = "prompt_eval_duration"
        case generationDuration = "generation_duration"
        case promptTokensPerSecond = "prompt_tokens_per_second"
        case generationTokensPerSecond = "generation_tokens_per_second"
        case modelLoadDuration = "model_load_duration"
        case totalTime = "total_time"
        case promptTokensDetails = "prompt_tokens_details"
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
    /// DeepSeek/Qwen/GLM convention — reasoning streamed in a separate field.
    let reasoningContent: String?
    /// Some servers (e.g. some vLLM, OpenRouter) expose reasoning under this key instead.
    let reasoning: String?

    enum CodingKeys: String, CodingKey {
        case role, content, reasoning
        case reasoningContent = "reasoning_content"
    }
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
