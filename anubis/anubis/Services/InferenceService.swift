//
//  InferenceService.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation
import Combine

/// Service that coordinates inference across multiple backends
@MainActor
final class InferenceService: ObservableObject {
    // MARK: - Published State

    /// Currently selected backend
    @Published private(set) var currentBackend: InferenceBackendType = .ollama

    /// Currently selected backend configuration (for OpenAI backends)
    @Published private(set) var currentOpenAIConfig: BackendConfiguration?

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

        // Observe configuration changes
        configManager.$configurations
            .sink { [weak self] _ in
                self?.reloadConfigurations()
            }
            .store(in: &cancellables)
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
        objectWillChange.send()
        lastError = nil
    }

    /// Switch to a specific OpenAI-compatible backend
    func setOpenAIBackend(_ config: BackendConfiguration) {
        // Set config before backend type — @Published on currentBackend
        // fires objectWillChange immediately, so config must be ready first
        currentOpenAIConfig = config
        currentBackend = .openai
        lastError = nil
    }

    /// Switch to the Apple Intelligence (Foundation Models) backend
    func setAppleIntelligenceBackend() {
        currentOpenAIConfig = nil
        currentBackend = .appleIntelligence
        lastError = nil
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

        var models: [ModelInfo] = []

        // Fetch from Ollama
        do {
            let ollamaModels = try await ollamaClient.listModels()
            models.append(contentsOf: ollamaModels)
            backendHealth[.ollama] = .healthy()
        } catch {
            backendHealth[.ollama] = .unhealthy(error: error.localizedDescription)
        }

        // Fetch from OpenAI-compatible backends
        for (id, client) in openAIClients {
            do {
                let openaiModels = try await client.listModels()
                models.append(contentsOf: openaiModels)
                openAIBackendHealth[id] = .healthy()
            } catch {
                openAIBackendHealth[id] = .unhealthy(error: error.localizedDescription)
            }
        }

        // Fetch from Apple Intelligence (returns empty if unavailable)
        let appleHealth = await appleIntelligenceClient.checkHealth()
        backendHealth[.appleIntelligence] = appleHealth
        if appleHealth.isRunning {
            if let appleModels = try? await appleIntelligenceClient.listModels() {
                models.append(contentsOf: appleModels)
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
