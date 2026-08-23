//
//  InferenceService.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation
import Combine
import os

/// Service that coordinates inference across multiple backends
@MainActor
final class InferenceService: ObservableObject {
    // MARK: - Published State

    /// Currently selected backend.
    ///
    /// Restored from `PersistedBackendID` on init when available, otherwise
    /// resolved by a parallel health probe (Apple Intelligence → OpenAI-compat
    /// configs → Ollama). No longer hardcoded to `.ollama`; that historical
    /// default was wrong for users running only LM Studio, MLX, vLLM, or AI.
    @Published private(set) var currentBackend: InferenceBackendType

    /// Currently selected backend configuration (for OpenAI backends)
    @Published private(set) var currentOpenAIConfig: BackendConfiguration?

    /// True when the persisted last-used backend exists but its health check
    /// failed on resolve. We keep it selected so the user sees what they had,
    /// but the picker can render an "(offline)" badge so the situation is
    /// obvious.
    @Published private(set) var currentBackendIsOffline = false

    /// Available models from all backends
    @Published private(set) var allModels: [ModelInfo] = []

    /// Backend health status
    @Published private(set) var backendHealth: [InferenceBackendType: BackendHealth] = [:]

    /// OpenAI backend health (keyed by configuration ID)
    @Published private(set) var openAIBackendHealth: [UUID: BackendHealth] = [:]

    /// Whether any inference is currently running
    @Published private(set) var isGenerating = false

    /// Last error that occurred
    @Published private(set) var lastError: AnubisError?

    // MARK: - Backend Clients

    /// Ollama client (exposed for model management)
    private(set) var ollamaClient: OllamaClient

    /// OpenAI-compatible clients (keyed by configuration ID)
    private var openAIClients: [UUID: OpenAICompatibleClient] = [:]

    /// Apple Intelligence (Foundation Models) on-device backend
    private let appleIntelligenceClient = AppleIntelligenceClient()

    /// Demo backend for App Store review mode
    private let demoBackend = DemoInferenceBackend()

    /// Backend configuration manager
    let configManager: BackendConfigurationManager

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(configManager: BackendConfigurationManager = BackendConfigurationManager()) {
        self.configManager = configManager

        // Initialize Ollama client with configured URL
        let ollamaConfig = configManager.ollamaConfig ?? .defaultOllama
        let ollamaURL = Constants.URLs.parse(ollamaConfig.baseURL, fallback: Constants.URLs.ollamaDefault)
        self.ollamaClient = OllamaClient(baseURL: ollamaURL)

        // Initialize OpenAI clients
        for config in configManager.openAIConfigs {
            openAIClients[config.id] = OpenAICompatibleClient(configuration: config)
        }

        // Restore persisted selection synchronously so the UI lands on the
        // right backend without flicker. Health is verified async below; if
        // the backend is offline, currentBackendIsOffline gets flipped on
        // and the picker UI surfaces it.
        if let persisted = PersistedBackendID.load(), Self.canApply(persisted, configManager: configManager) {
            self.currentBackend = persisted.type
            if persisted.type == .openai, let configId = persisted.openAIConfigId {
                self.currentOpenAIConfig = configManager.openAIConfigs.first { $0.id == configId }
            }
        } else {
            // Fresh launch (or persisted choice references a deleted config).
            // Use Ollama as the placeholder for the brief window before the
            // async health probe lands on the actual right backend; not a
            // user-facing default.
            self.currentBackend = .ollama
        }

        // Observe configuration changes
        configManager.$configurations
            .sink { [weak self] _ in
                self?.reloadConfigurations()
            }
            .store(in: &cancellables)

        // Async: verify the persisted choice is healthy, or for fresh users
        // probe the priority order and land on the first responding backend.
        Task { await self.resolveInitialBackend() }
    }

    /// Check whether a persisted selection still refers to a valid configuration.
    private static func canApply(_ persisted: PersistedBackendID, configManager: BackendConfigurationManager) -> Bool {
        switch persisted.type {
        case .ollama, .appleIntelligence:
            return true
        case .openai:
            guard let configId = persisted.openAIConfigId else { return false }
            return configManager.openAIConfigs.contains { $0.id == configId }
        }
    }

    /// Decide the initial backend.
    ///
    /// 1. If there's a persisted selection, verify it's reachable. If yes,
    ///    keep it. If no, mark `currentBackendIsOffline` so the picker can
    ///    render an offline badge — but keep the selection rather than
    ///    silently jumping the user to a different backend.
    /// 2. No persisted selection (fresh install): probe in priority order
    ///    Apple Intelligence → each OpenAI-compat config → Ollama, land on
    ///    the first healthy one. No Ollama-first bias.
    private func resolveInitialBackend() async {
        await checkAllBackends()

        if let persisted = PersistedBackendID.load(), Self.canApply(persisted, configManager: configManager) {
            currentBackendIsOffline = !isHealthy(persisted)
            Log.app.info("Backend resolve: restored persisted \(persisted.type.rawValue, privacy: .public)\(persisted.openAIConfigId.map { " (config \($0.uuidString))" } ?? "", privacy: .public) — offline: \(self.currentBackendIsOffline)")
            return
        }

        // Fresh-launch priority order.
        if backendHealth[.appleIntelligence]?.isRunning == true {
            currentBackend = .appleIntelligence
            currentOpenAIConfig = nil
            persistCurrentSelection()
            Log.app.info("Backend resolve: fresh launch → Apple Intelligence")
            return
        }
        for config in configManager.openAIConfigs {
            if openAIBackendHealth[config.id]?.isRunning == true {
                setOpenAIBackend(config)
                persistCurrentSelection()
                Log.app.info("Backend resolve: fresh launch → OpenAI-compat \(config.name, privacy: .public)")
                return
            }
        }
        if backendHealth[.ollama]?.isRunning == true {
            currentBackend = .ollama
            currentOpenAIConfig = nil
            persistCurrentSelection()
            Log.app.info("Backend resolve: fresh launch → Ollama (last in priority order)")
            return
        }
        Log.app.info("Backend resolve: no backend healthy; UI will show disconnected")
        // Nothing healthy; leave currentBackend at its placeholder and let
        // the UI surface the disconnected state through the existing health
        // indicator.
    }

    private func isHealthy(_ persisted: PersistedBackendID) -> Bool {
        switch persisted.type {
        case .ollama:
            return backendHealth[.ollama]?.isRunning == true
        case .openai:
            guard let id = persisted.openAIConfigId else { return false }
            return openAIBackendHealth[id]?.isRunning == true
        case .appleIntelligence:
            return backendHealth[.appleIntelligence]?.isRunning == true
        }
    }

    /// Snapshot the current backend choice into PersistedBackendID and write
    /// it to UserDefaults so the next launch restores the same selection.
    func persistCurrentSelection() {
        let persisted = PersistedBackendID(
            type: currentBackend,
            openAIConfigId: currentBackend == .openai ? currentOpenAIConfig?.id : nil
        )
        persisted.save()
    }

    /// Reload backend configurations
    func reloadConfigurations() {
        // Update Ollama client if URL changed
        if let ollamaConfig = configManager.ollamaConfig {
            let newURL = Constants.URLs.parse(ollamaConfig.baseURL, fallback: Constants.URLs.ollamaDefault)
            ollamaClient = OllamaClient(baseURL: newURL)
        }

        // Update OpenAI clients
        openAIClients.removeAll()
        for config in configManager.openAIConfigs {
            openAIClients[config.id] = OpenAICompatibleClient(configuration: config)
        }

        // If current OpenAI config was deleted, switch back to Ollama
        if currentBackend == .openai {
            if let currentConfig = currentOpenAIConfig {
                if !configManager.openAIConfigs.contains(where: { $0.id == currentConfig.id }) {
                    // Current config was deleted, switch to Ollama
                    currentBackend = .ollama
                    currentOpenAIConfig = nil
                }
            } else if openAIClients.isEmpty {
                // No OpenAI configs available
                currentBackend = .ollama
            }
        }

        // Trigger objectWillChange to update UI
        objectWillChange.send()
    }

    // MARK: - Backend Management

    /// Switch to a different backend
    func setBackend(_ backend: InferenceBackendType) {
        currentBackend = backend
        // Only clear OpenAI config when switching away from OpenAI —
        // BenchmarkViewModel's selectedBackend didSet calls setBackend(.openai)
        // as a sync echo, which must not wipe the config set by setOpenAIBackend
        if backend != .openai {
            currentOpenAIConfig = nil
        }
        currentBackendIsOffline = false
        objectWillChange.send()
        lastError = nil
        persistCurrentSelection()
    }

    /// Switch to a specific OpenAI-compatible backend
    func setOpenAIBackend(_ config: BackendConfiguration) {
        // Set config before backend type — @Published on currentBackend
        // fires objectWillChange immediately, so config must be ready first
        currentOpenAIConfig = config
        currentBackend = .openai
        currentBackendIsOffline = false
        lastError = nil
        persistCurrentSelection()
    }

    /// Switch to the Apple Intelligence (Foundation Models) backend
    func setAppleIntelligenceBackend() {
        currentOpenAIConfig = nil
        currentBackend = .appleIntelligence
        currentBackendIsOffline = false
        lastError = nil
        persistCurrentSelection()
    }

    /// Get the currently active backend
    var activeBackend: any InferenceBackend {
        // Use demo backend when in demo mode
        if DemoMode.isEnabled {
            return demoBackend
        }

        switch currentBackend {
        case .ollama:
            return ollamaClient
        case .openai:
            if let config = currentOpenAIConfig, let client = openAIClients[config.id] {
                return client
            }
            // Fallback to first available OpenAI client
            if let firstClient = openAIClients.values.first {
                return firstClient
            }
            // Ultimate fallback
            return ollamaClient
        case .appleIntelligence:
            return appleIntelligenceClient
        }
    }

    /// Check health of all backends
    func checkAllBackends() async {
        // In demo mode, report all backends as healthy
        if DemoMode.isEnabled {
            backendHealth[.ollama] = .healthy(version: "0.5.4 (Demo)", modelCount: DemoMode.mockModels.count)
            return
        }

        let ollama = await ollamaClient.checkHealth()
        backendHealth[.ollama] = ollama

        // Check OpenAI-compatible backends
        for (id, client) in openAIClients {
            let health = await client.checkHealth()
            openAIBackendHealth[id] = health
        }

        let appleHealth = await appleIntelligenceClient.checkHealth()
        backendHealth[.appleIntelligence] = appleHealth
    }

    /// Check if the current backend is available
    func isCurrentBackendAvailable() async -> Bool {
        let health = await activeBackend.checkHealth()
        backendHealth[currentBackend] = health
        return health.isRunning
    }

    // MARK: - Model Management

    /// Refresh models from all backends
    func refreshAllModels() async {
        // In demo mode, use mock models
        if DemoMode.isEnabled {
            allModels = DemoMode.mockModels.sorted { $0.name < $1.name }
            return
        }

        // Query every backend CONCURRENTLY. This used to be sequential, so a
        // single slow or unreachable configured server (a sleeping remote Mac,
        // a stale .local hostname) delayed every other backend's model list by
        // its full timeout. Now the wait is max(one backend), not the sum.
        enum FetchResult {
            case ollama(Result<[ModelInfo], Error>)
            case openAI(UUID, Result<[ModelInfo], Error>)
            case apple(BackendHealth, [ModelInfo])
        }

        let ollama = ollamaClient
        let openAI = openAIClients
        let apple = appleIntelligenceClient

        let results = await withTaskGroup(of: FetchResult.self) { group in
            group.addTask {
                do { return .ollama(.success(try await ollama.listModels())) }
                catch { return .ollama(.failure(error)) }
            }
            for (id, client) in openAI {
                group.addTask {
                    do { return .openAI(id, .success(try await client.listModels())) }
                    catch { return .openAI(id, .failure(error)) }
                }
            }
            group.addTask {
                let health = await apple.checkHealth()
                let models = health.isRunning ? ((try? await apple.listModels()) ?? []) : []
                return .apple(health, models)
            }
            var collected: [FetchResult] = []
            for await r in group { collected.append(r) }
            return collected
        }

        var models: [ModelInfo] = []
        for result in results {
            switch result {
            case .ollama(.success(let m)):
                models.append(contentsOf: m)
                backendHealth[.ollama] = .healthy()
            case .ollama(.failure(let e)):
                backendHealth[.ollama] = .unhealthy(error: e.localizedDescription)
            case .openAI(let id, .success(let m)):
                models.append(contentsOf: m)
                openAIBackendHealth[id] = .healthy()
            case .openAI(let id, .failure(let e)):
                openAIBackendHealth[id] = .unhealthy(error: e.localizedDescription)
            case .apple(let health, let m):
                backendHealth[.appleIntelligence] = health
                models.append(contentsOf: m)
            }
        }

        allModels = models.sorted { $0.name < $1.name }
    }

    /// Get models for the current backend only
    func modelsForCurrentBackend() -> [ModelInfo] {
        if currentBackend == .openai, let configId = currentOpenAIConfig?.id {
            // Filter by specific OpenAI configuration
            return allModels.filter { $0.backend == .openai && $0.openAIConfigId == configId }
        }
        return allModels.filter { $0.backend == currentBackend }
    }

    /// Get models for a specific backend
    func models(for backend: InferenceBackendType) -> [ModelInfo] {
        allModels.filter { $0.backend == backend }
    }

    /// Get models for a specific OpenAI configuration
    func models(for config: BackendConfiguration) -> [ModelInfo] {
        allModels.filter { $0.backend == .openai && $0.openAIConfigId == config.id }
    }

    // MARK: - Inference

    /// Generate a streaming response
    ///
    /// Returns the backend stream directly — callers are responsible for
    /// consuming off MainActor and calling `clearGenerating()` when done.
    func generate(request: InferenceRequest) async -> AsyncThrowingStream<InferenceChunk, Error> {
        let backend = activeBackend
        isGenerating = true
        lastError = nil
        return await backend.generate(request: request)
    }

    /// Reset isGenerating flag — called by ViewModel when stream consumption finishes
    func clearGenerating() {
        isGenerating = false
    }

    /// Generate a complete (non-streaming) response
    func generateComplete(request: InferenceRequest) async throws -> InferenceResponse {
        isGenerating = true
        lastError = nil

        defer { isGenerating = false }

        do {
            return try await activeBackend.generateComplete(request: request)
        } catch {
            if let anubisError = error as? AnubisError {
                lastError = anubisError
            } else {
                lastError = .networkError(underlying: error)
            }
            throw error
        }
    }

    // MARK: - Convenience Methods

    /// Quick generation with just model and prompt
    func generate(model: String, prompt: String) async -> AsyncThrowingStream<InferenceChunk, Error> {
        let request = InferenceRequest(model: model, prompt: prompt)
        return await generate(request: request)
    }

    /// Get OpenAI client for a specific configuration
    func openAIClient(for configId: UUID) -> OpenAICompatibleClient? {
        openAIClients[configId]
    }
}
