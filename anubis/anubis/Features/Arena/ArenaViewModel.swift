//
//  ArenaViewModel.swift
//  anubis
//
//  Created on 2026-01-26.
//

import Foundation
import Combine
import GRDB
import os

/// ViewModel for the Arena comparison module
@MainActor
final class ArenaViewModel: ObservableObject {
    // MARK: - Published State

    /// Available models for selection
    @Published private(set) var availableModels: [ModelInfo] = []

    /// Currently running models in Ollama
    @Published private(set) var runningModels: [RunningModel] = []

    /// Selected model for side A
    @Published var modelA: ModelInfo?

    /// Selected model for side B
    @Published var modelB: ModelInfo?

    /// Backend for model A
    @Published var backendA: InferenceBackendType = .ollama

    /// Backend for model B
    @Published var backendB: InferenceBackendType = .ollama

    /// OpenAI config for side A (when backendA == .openai)
    @Published var openAIConfigA: BackendConfiguration?

    /// OpenAI config for side B (when backendB == .openai)
    @Published var openAIConfigB: BackendConfiguration?

    /// Shared prompt
    @Published var prompt = ""

    /// System prompt (optional)
    @Published var systemPrompt = ""

    // MARK: - Generation Parameters

    /// Temperature for sampling (0.0 - 2.0)
    @Published var temperature: Double = 0.7

    /// Top-p sampling parameter (0.0 - 1.0)
    @Published var topP: Double = 0.9

    /// Maximum tokens to generate
    @Published var maxTokens: Int = 2048

    /// Execution mode
    @Published var executionMode: ArenaExecutionMode = .sequential

    /// Whether comparison is running
    @Published private(set) var isRunning = false

    /// Current phase description
    @Published private(set) var currentPhase = ""

    /// Response from model A
    @Published private(set) var responseA = ""

    /// Response from model B
    @Published private(set) var responseB = ""

    /// Session for model A (after completion)
    @Published private(set) var sessionA: BenchmarkSession?

    /// Session for model B (after completion)
    @Published private(set) var sessionB: BenchmarkSession?

    /// Current comparison (after both complete)
    @Published private(set) var currentComparison: ArenaComparison?

    /// Elapsed time for model A
    @Published private(set) var elapsedTimeA: TimeInterval?

    /// Elapsed time for model B
    @Published private(set) var elapsedTimeB: TimeInterval?

    /// Recent comparisons
    @Published private(set) var recentComparisons: [ArenaComparisonResult] = []

    /// Debug inspector state for model A
    @Published private(set) var debugStateA = DebugInspectorState()

    /// Debug inspector state for model B
    @Published private(set) var debugStateB = DebugInspectorState()

    /// Error state
    @Published private(set) var error: AnubisError?

    // MARK: - Dependencies

    private let appState: AppState
    private let inferenceService: InferenceService
    private let metricsService: MetricsService
    private let databaseManager: DatabaseManager

    private var comparisonTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        appState: AppState,
        inferenceService: InferenceService,
        metricsService: MetricsService,
        databaseManager: DatabaseManager
    ) {
        self.appState = appState
        self.inferenceService = inferenceService
        self.metricsService = metricsService
        self.databaseManager = databaseManager
    }

    // MARK: - Public Methods

    /// Load available models from backends
    func loadModels() async {
        await inferenceService.refreshAllModels()
        availableModels = inferenceService.allModels

        // Set defaults if not set
        let ollamaModels = availableModels.filter { $0.backend == .ollama }
        if modelA == nil {
            modelA = ollamaModels.first
        }
        if modelB == nil {
            modelB = ollamaModels.dropFirst().first ?? ollamaModels.first
        }

        // Refresh running models
        await refreshRunningModels()
    }

    /// Refresh list of running models
    func refreshRunningModels() async {
        // In demo mode, no actual models are running
        if DemoMode.isEnabled {
            runningModels = []
            return
        }

        do {
            runningModels = try await inferenceService.ollamaClient.listRunningModels()
        } catch {
            runningModels = []
        }
    }

    /// Unload a specific model
    func unloadModel(_ model: RunningModel) async {
        // No-op in demo mode
        if DemoMode.isEnabled { return }

        do {
            try await inferenceService.ollamaClient.unloadModel(model.name)
            await refreshRunningModels()
        } catch {
            self.error = .invalidResponse(details: "Failed to unload model: \(error.localizedDescription)")
        }
    }

    /// Unload all models
    func unloadAllModels() async {
        for model in runningModels {
            await unloadModel(model)
        }
    }

    /// Start the comparison
    func startComparison() {
        guard !isRunning else { return }
        guard let modelA = modelA, let modelB = modelB else {
            error = .modelLoadFailed(modelId: "none", reason: "Select both models")
            return
        }
        guard !prompt.isEmpty else {
            error = .modelLoadFailed(modelId: "none", reason: "Enter a prompt")
            return
        }

        // Reset state
        responseA = ""
        responseB = ""
        sessionA = nil
        sessionB = nil
        currentComparison = nil
        elapsedTimeA = nil
        elapsedTimeB = nil
        debugStateA.reset()
        debugStateB.reset()
        error = nil
        currentPhase = ""
        isRunning = true
        appState.isArenaRunning = true

        comparisonTask = Task {
            do {
                switch executionMode {
                case .sequential:
                    try await runSequential(modelA: modelA, modelB: modelB)
                case .parallel:
                    try await runParallel(modelA: modelA, modelB: modelB)
                }

                // Create comparison record
                if let sA = sessionA, let sB = sessionB,
                   let idA = sA.id, let idB = sB.id {
                    var comparison = ArenaComparison(
                        sessionAId: idA,
                        sessionBId: idB,
                        prompt: prompt,
                        systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
                        executionMode: executionMode
                    )
                    try await databaseManager.queue.write { db in
                        try comparison.insert(db)
                    }
                    currentComparison = comparison
                }

                await loadRecentComparisons()
            } catch is CancellationError {
                currentPhase = "Cancelled"
            } catch let anubisError as AnubisError {
                self.error = anubisError
            } catch {
                self.error = .invalidResponse(details: error.localizedDescription)
            }

            isRunning = false
            appState.isArenaRunning = false
            currentPhase = ""
        }
    }

    /// Stop the current comparison
    func stopComparison() {
        comparisonTask?.cancel()
        comparisonTask = nil
        currentPhase = "Cancelling..."
        // isRunning will be set to false when the comparisonTask finishes
    }

    /// Force reset all state — use when a run gets stuck or leaves dirty state
    func forceReset() {
        comparisonTask?.cancel()
        comparisonTask = nil
        isRunning = false
        appState.isArenaRunning = false
        currentPhase = ""
        responseA = ""
        responseB = ""
        sessionA = nil
        sessionB = nil
        currentComparison = nil
        elapsedTimeA = nil
        elapsedTimeB = nil
        debugStateA.reset()
        debugStateB.reset()
        error = nil
    }

    /// Set the winner for the current comparison
    func setWinner(_ winner: ArenaWinner?) async {
        guard var comparison = currentComparison else { return }
        comparison.setWinner(winner)

        do {
            try await databaseManager.queue.write { db in
                try comparison.update(db)
            }
            currentComparison = comparison
            await loadRecentComparisons()
        } catch {
            self.error = .invalidResponse(details: "Failed to save winner")
        }
    }

    /// Load recent comparisons
    func loadRecentComparisons() async {
        do {
            let comparisons = try await databaseManager.queue.read { db in
                try ArenaComparison.fetchRecent(db: db, limit: 20)
            }

            var results: [ArenaComparisonResult] = []
            for comparison in comparisons {
                if let (_, sessionA, sessionB) = try await databaseManager.queue.read({ db in
                    try ArenaComparison.fetchWithSessions(db: db, id: comparison.id!)
                }), let sA = sessionA, let sB = sessionB {
                    results.append(ArenaComparisonResult(comparison: comparison, sessionA: sA, sessionB: sB))
                }
            }
            recentComparisons = results
        } catch {
            print("Failed to load comparisons: \(error)")
        }
    }

    // MARK: - Private Methods

    private func runSequential(modelA: ModelInfo, modelB: ModelInfo) async throws {
        // Run Model A
        currentPhase = "Running \(modelA.name)..."
        let startA = Date()
        sessionA = try await runSingleModel(
            model: modelA,
            backend: backendA,
            openAIConfig: openAIConfigA,
            updateResponse: { [weak self] text in
                self?.responseA = text
            },
            updateDebug: { [weak self] state in
                self?.debugStateA = state
            }
        )
        elapsedTimeA = Date().timeIntervalSince(startA)

        // Unload Model A if using Ollama (skip in demo mode)
        if backendA == .ollama && !DemoMode.isEnabled {
            currentPhase = "Unloading \(modelA.name)..."
            try? await inferenceService.ollamaClient.unloadModel(modelA.id)
            await refreshRunningModels()
        }

        try Task.checkCancellation()

        // Run Model B
        currentPhase = "Running \(modelB.name)..."
        let startB = Date()
        sessionB = try await runSingleModel(
            model: modelB,
            backend: backendB,
            openAIConfig: openAIConfigB,
            updateResponse: { [weak self] text in
                self?.responseB = text
            },
            updateDebug: { [weak self] state in
                self?.debugStateB = state
            }
        )
        elapsedTimeB = Date().timeIntervalSince(startB)

        // Optionally unload Model B (skip in demo mode)
        if backendB == .ollama && !DemoMode.isEnabled {
            try? await inferenceService.ollamaClient.unloadModel(modelB.id)
            await refreshRunningModels()
        }

        currentPhase = "Complete"
    }

    private func runParallel(modelA: ModelInfo, modelB: ModelInfo) async throws {
        currentPhase = "Running both models..."
        let startTime = Date()

        // Run each model in its own task to track individual completion times
        let taskAHandle = Task { @MainActor [weak self] () -> BenchmarkSession in
            guard let self else {
                throw AnubisError.invalidResponse(details: "Model run was cancelled")
            }
            let session = try await self.runSingleModel(
                model: modelA,
                backend: self.backendA,
                openAIConfig: self.openAIConfigA,
                updateResponse: { [weak self] text in
                    self?.responseA = text
                },
                updateDebug: { [weak self] state in
                    self?.debugStateA = state
                }
            )
            self.elapsedTimeA = Date().timeIntervalSince(startTime)
            return session
        }

        let taskBHandle = Task { @MainActor [weak self] () -> BenchmarkSession in
            guard let self else {
                throw AnubisError.invalidResponse(details: "Model run was cancelled")
            }
            let session = try await self.runSingleModel(
                model: modelB,
                backend: self.backendB,
                openAIConfig: self.openAIConfigB,
                updateResponse: { [weak self] text in
                    self?.responseB = text
                },
                updateDebug: { [weak self] state in
                    self?.debugStateB = state
                }
            )
            self.elapsedTimeB = Date().timeIntervalSince(startTime)
            return session
        }

        sessionA = try await taskAHandle.value
        sessionB = try await taskBHandle.value

        currentPhase = "Complete"
    }

    /// Resolve the backend client directly, avoiding shared InferenceService state mutation.
    /// This prevents race conditions when running models in parallel.
    private func resolveBackend(
        backend: InferenceBackendType,
        openAIConfig: BackendConfiguration?
    ) -> any InferenceBackend {
        // In demo mode, always use the demo backend via activeBackend
        if DemoMode.isEnabled {
            return inferenceService.activeBackend
        }

        if backend == .openai, let config = openAIConfig,
           let client = inferenceService.openAIClient(for: config.id) {
            return client
        }
        return inferenceService.ollamaClient
    }

    private func runSingleModel(
        model: ModelInfo,
        backend: InferenceBackendType,
        openAIConfig: BackendConfiguration?,
        updateResponse: @escaping (String) -> Void,
        updateDebug: @escaping (DebugInspectorState) -> Void
    ) async throws -> BenchmarkSession {
        var session = BenchmarkSession(
            modelId: model.id,
            modelName: model.name,
            backend: backend,
            prompt: prompt
        )

        // Save session to get ID
        try await databaseManager.queue.write { db in
            try session.insert(db)
        }

        let request = InferenceRequest(
            model: model.id,
            prompt: prompt,
            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP
        )

        // Resolve backend directly — no shared state mutation
        let resolvedBackend = resolveBackend(backend: backend, openAIConfig: openAIConfig)

        // Initialize debug state
        let endpointURL = connectionURL(for: backend, openAIConfig: openAIConfig)
        var debugState = DebugInspectorState()
        debugState.backendType = backend
        debugState.endpointURL = endpointURL
        debugState.modelId = model.id
        debugState.requestTimestamp = Date()
        debugState.promptSnippet = String(prompt.prefix(200))
        debugState.systemPrompt = systemPrompt.isEmpty ? nil : systemPrompt
        debugState.maxTokens = maxTokens
        debugState.temperature = temperature
        debugState.topP = topP
        debugState.phase = .connecting
        debugState.requestJSON = DebugInspectorState.buildRequestJSON(
            backend: backend, model: model.id, prompt: prompt,
            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
            maxTokens: maxTokens, temperature: temperature, topP: topP
        )
        updateDebug(debugState)

        // Start metrics collection for sample recording
        metricsService.startCollecting()

        var responseText = ""
        var stats: InferenceStats?
        let startTime = Date()
        var firstTokenTime: Date?
        var chunkCount = 0
        var tokenCount = 0

        // Sample collection for arena (lightweight, in-memory)
        var collectedSamples: [BenchmarkSample] = []
        let sampleInterval: TimeInterval = 0.5
        var lastSampleTime = startTime

        let stream = await resolvedBackend.generate(request: request)

        // Wrap stream consumption with a timeout to prevent hanging on stalled backends
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    for try await chunk in stream {
                        if Task.isCancelled { break }

                        if firstTokenTime == nil && !chunk.text.isEmpty {
                            firstTokenTime = Date()
                            debugState.firstChunkAt = firstTokenTime
                        }

                        responseText += chunk.text
                        chunkCount += 1
                        tokenCount += 1
                        debugState.chunksReceived = chunkCount
                        debugState.bytesReceived += chunk.text.utf8.count
                        debugState.lastChunkAt = Date()
                        debugState.phase = .streaming

                        updateResponse(responseText)

                        // Collect metrics samples at fixed interval
                        let now = Date()
                        if now.timeIntervalSince(lastSampleTime) >= sampleInterval,
                           let sessionId = session.id,
                           let metrics = self.metricsService.latestMetrics {
                            let tps = now.timeIntervalSince(startTime) > 0
                                ? Double(tokenCount) / now.timeIntervalSince(startTime)
                                : 0
                            let sample = BenchmarkSample(
                                sessionId: sessionId,
                                metrics: metrics,
                                tokensGenerated: tokenCount,
                                cumulativeTokensPerSecond: tps
                            )
                            collectedSamples.append(sample)
                            lastSampleTime = now
                        }

                        // Throttle debug UI updates: every 10 chunks or on done
                        if chunkCount % 10 == 0 || chunk.done {
                            updateDebug(debugState)
                        }

                        if chunk.done, let chunkStats = chunk.stats {
                            stats = chunkStats
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(120))
                    throw AnubisError.inferenceTimeout(after: 120)
                }
                // First task to finish wins; cancel the other
                do {
                    try await group.next()
                } catch is CancellationError {
                    throw CancellationError()
                }
                group.cancelAll()
            }
        } catch {
            metricsService.stopCollecting()
            debugState.phase = .error
            debugState.errorMessage = error.localizedDescription
            debugState.completedAt = Date()
            updateDebug(debugState)
            throw error
        }

        metricsService.stopCollecting()

        // Compute power summary from collected samples
        let powerSummary = BenchmarkSample.computePowerSummary(from: collectedSamples)
        let backendName = metricsService.latestMetrics?.backendProcessName

        // Complete session
        let ttft = firstTokenTime.map { $0.timeIntervalSince(startTime) }
        if let finalStats = stats {
            session.complete(
                with: finalStats,
                response: responseText,
                timeToFirstToken: ttft,
                peakMemoryBytes: nil,
                powerSummary: powerSummary,
                backendProcessName: backendName
            )
            debugState.finalTokensPerSecond = finalStats.tokensPerSecond
            debugState.finalTotalTokens = finalStats.totalTokens
        } else {
            let duration = Date().timeIntervalSince(startTime)
            let manualStats = InferenceStats(
                totalTokens: 0,
                promptTokens: 0,
                completionTokens: 0,
                totalDuration: duration,
                promptEvalDuration: 0,
                evalDuration: duration,
                loadDuration: 0,
                contextLength: 0
            )
            session.complete(
                with: manualStats,
                response: responseText,
                timeToFirstToken: ttft,
                peakMemoryBytes: nil,
                powerSummary: powerSummary,
                backendProcessName: backendName
            )
        }

        debugState.phase = .complete
        debugState.completedAt = Date()
        updateDebug(debugState)

        // Update session in database
        try await databaseManager.queue.write { db in
            try session.update(db)
        }

        // Batch-write collected samples to database
        if !collectedSamples.isEmpty {
            let samplesToWrite = collectedSamples
            Task.detached(priority: .utility) { [databaseManager] in
                do {
                    try await databaseManager.queue.write { db in
                        for var sample in samplesToWrite {
                            try sample.insert(db)
                        }
                    }
                } catch {
                    Log.benchmark.error("Arena: Failed to write samples: \(error.localizedDescription)")
                }
            }
        }

        return session
    }
}

// MARK: - Convenience Extensions

extension ArenaViewModel {
    /// Access to config manager for OpenAI backends
    var configManager: BackendConfigurationManager {
        inferenceService.configManager
    }

    /// Models available for backend A
    var modelsForBackendA: [ModelInfo] {
        if backendA == .openai, let configId = openAIConfigA?.id {
            return availableModels.filter { $0.backend == .openai && $0.openAIConfigId == configId }
        }
        return availableModels.filter { $0.backend == backendA }
    }

    /// Models available for backend B
    var modelsForBackendB: [ModelInfo] {
        if backendB == .openai, let configId = openAIConfigB?.id {
            return availableModels.filter { $0.backend == .openai && $0.openAIConfigId == configId }
        }
        return availableModels.filter { $0.backend == backendB }
    }

    /// Set backend A to an OpenAI-compatible server
    func setOpenAIBackendA(_ config: BackendConfiguration) {
        backendA = .openai
        openAIConfigA = config
        // Update model selection for new backend
        modelA = modelsForBackendA.first
    }

    /// Set backend B to an OpenAI-compatible server
    func setOpenAIBackendB(_ config: BackendConfiguration) {
        backendB = .openai
        openAIConfigB = config
        // Update model selection for new backend
        modelB = modelsForBackendB.first
    }

    /// Display name for backend A
    var backendADisplayName: String {
        if backendA == .openai, let config = openAIConfigA {
            return config.name
        }
        return backendA.displayName
    }

    /// Display name for backend B
    var backendBDisplayName: String {
        if backendB == .openai, let config = openAIConfigB {
            return config.name
        }
        return backendB.displayName
    }

    /// Connection URL for backend A
    var backendAURL: String {
        connectionURL(for: backendA, openAIConfig: openAIConfigA)
    }

    /// Connection URL for backend B
    var backendBURL: String {
        connectionURL(for: backendB, openAIConfig: openAIConfigB)
    }

    private func connectionURL(for backend: InferenceBackendType, openAIConfig: BackendConfiguration?) -> String {
        switch backend {
        case .ollama:
            return configManager.ollamaConfig?.baseURL ?? "http://localhost:11434"
        case .openai:
            return openAIConfig?.baseURL ?? "—"
        case .mlx:
            return configManager.configurations.first(where: { $0.type == .mlx })?.baseURL ?? "—"
        }
    }

    /// Estimated memory for current selection
    var estimatedMemoryUsage: String {
        var total: Int64 = 0
        if let a = modelA, let size = a.sizeBytes {
            total += size
        }
        if let b = modelB, let size = b.sizeBytes, executionMode == .parallel {
            total += size
        }
        return total > 0 ? Formatters.bytes(total) : "Unknown"
    }

    /// Whether we can start a comparison
    var canStart: Bool {
        modelA != nil && modelB != nil && !prompt.isEmpty && !isRunning
    }
}
