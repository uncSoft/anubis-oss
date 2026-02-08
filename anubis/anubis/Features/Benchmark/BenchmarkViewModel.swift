//
//  BenchmarkViewModel.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation
import Combine
import GRDB
import os

/// Separate observable for chart data so chart updates don't trigger
/// re-evaluation of text streaming or other UI elements.
@MainActor
final class BenchmarkChartStore: ObservableObject {
    @Published private(set) var chartData: BenchmarkChartData = .empty

    func update(_ data: BenchmarkChartData) {
        chartData = data
    }

    func reset() {
        chartData = .empty
    }
}

/// ViewModel for the Benchmark module
/// Manages benchmark sessions, coordinates inference with metrics collection
@MainActor
final class BenchmarkViewModel: ObservableObject {
    // MARK: - Published State

    /// Current benchmark session (if running or just completed)
    @Published private(set) var currentSession: BenchmarkSession?

    /// Whether a benchmark is currently running
    @Published private(set) var isRunning = false

    /// Current real-time metrics during benchmark
    @Published private(set) var currentMetrics: SystemMetrics?

    /// Accumulated response text
    @Published private(set) var responseText = ""

    /// When false, suppress response text rendering during benchmark for minimal CPU interference.
    /// Text is still accumulated internally and shown on completion.
    @Published var streamResponse = true

    /// Whether to show live charts during benchmark
    @Published var showLiveCharts = true

    /// Current tokens per second (real-time average)
    @Published private(set) var currentTokensPerSecond: Double = 0

    /// Peak tokens per second observed during benchmark
    @Published private(set) var peakTokensPerSecond: Double = 0

    /// Time to first token (live tracking)
    @Published private(set) var timeToFirstToken: TimeInterval?

    /// Peak memory usage during benchmark
    @Published private(set) var currentPeakMemory: Int64 = 0

    /// Model memory info (from Ollama /api/ps)
    @Published private(set) var modelMemoryTotal: Int64 = 0
    @Published private(set) var modelMemoryGPU: Int64 = 0
    @Published private(set) var modelMemoryCPU: Int64 = 0

    /// Running average GPU power during benchmark
    @Published private(set) var avgGpuPower: Double = 0

    /// Peak GPU power observed during benchmark
    @Published private(set) var peakGpuPower: Double = 0

    /// Running average system power during benchmark
    @Published private(set) var avgSystemPower: Double = 0

    /// Peak system power observed during benchmark
    @Published private(set) var peakSystemPower: Double = 0

    /// Total tokens generated so far
    @Published private(set) var tokensGenerated = 0

    /// Elapsed time since benchmark start
    @Published private(set) var elapsedTime: TimeInterval = 0

    /// Available models for selection
    @Published private(set) var availableModels: [ModelInfo] = []

    /// Selected model for benchmark
    @Published var selectedModel: ModelInfo?

    /// Selected backend (synced with inferenceService)
    @Published var selectedBackend: InferenceBackendType = .ollama {
        didSet {
            if oldValue != selectedBackend {
                // Sync with inference service
                inferenceService.setBackend(selectedBackend)
            }
        }
    }

    /// Active connection name (resolved from backend + config)
    var connectionName: String {
        switch selectedBackend {
        case .ollama:
            return inferenceService.configManager.ollamaConfig?.name ?? "Ollama"
        case .openai:
            return inferenceService.currentOpenAIConfig?.name ?? "OpenAI Compatible"
        case .mlx:
            return inferenceService.configManager.configurations.first(where: { $0.type == .mlx })?.name ?? "MLX"
        }
    }

    /// Active connection URL (resolved from backend + config)
    var connectionURL: String {
        switch selectedBackend {
        case .ollama:
            return inferenceService.configManager.ollamaConfig?.baseURL ?? "http://localhost:11434"
        case .openai:
            return inferenceService.currentOpenAIConfig?.baseURL ?? "—"
        case .mlx:
            return inferenceService.configManager.configurations.first(where: { $0.type == .mlx })?.baseURL ?? "—"
        }
    }

    /// Prompt text for benchmark
    @Published var promptText = "Explain the concept of recursion in programming with a simple example."

    /// System prompt (optional)
    @Published var systemPrompt = ""

    // MARK: - Generation Parameters

    /// Temperature for sampling (0.0 - 2.0)
    @Published var temperature: Double = 0.7

    /// Top-p sampling parameter (0.0 - 1.0)
    @Published var topP: Double = 0.9

    /// Maximum tokens to generate
    @Published var maxTokens: Int = 2048

    /// Debug inspector state
    @Published private(set) var debugState = DebugInspectorState()

    /// Available processes for custom selection
    @Published private(set) var candidateProcesses: [ProcessCandidate] = []

    /// Whether a custom process is being monitored
    @Published private(set) var isCustomProcessActive = false

    /// Error state
    @Published private(set) var error: AnubisError?

    /// Historical sessions
    @Published private(set) var recentSessions: [BenchmarkSession] = []

    /// Collected samples for current session (internal, not directly observed)
    private var currentSamplesInternal: [BenchmarkSample] = []

    /// Chart data lives in a separate observable to avoid invalidating the
    /// entire view hierarchy (especially text streaming) on every chart update.
    let chartStore = BenchmarkChartStore()

    // MARK: - Dependencies

    private let inferenceService: InferenceService
    private let metricsService: MetricsService
    let databaseManager: DatabaseManager

    private var benchmarkTask: Task<Void, Never>?
    private var metricsSubscription: AnyCancellable?
    private var elapsedTimer: Timer?
    private var benchmarkStartTime: Date?
    private var sampleTimer: Timer?
    private var uiUpdateTimer: Timer?

    // Sampling configuration
    private let sampleInterval: TimeInterval = 0.5   // Sample metrics at 2Hz (was 0.1s/10Hz — reduced to match MetricsService polling)
    private let uiUpdateInterval: TimeInterval = 0.1  // 10 FPS for smooth text streaming
    private let chartUpdateInterval: TimeInterval = 0.5  // Charts update at 2Hz (aligned with sample rate)
    private var lastChartUpdate: Date = .distantPast
    private let maxChartDataPoints = 250  // Limit chart points to keep rendering fast

    // Buffers for batched UI updates (non-published for performance)
    private var textBuffer: String = ""
    private var pendingTokenCount: Int = 0
    private var pendingTps: Double = 0
    private var pendingPeakTps: Double = 0

    // Running power accumulators (updated each sample, flushed to @Published at UI rate)
    private var gpuPowerSum: Double = 0
    private var systemPowerSum: Double = 0
    private var powerSampleCount: Int = 0
    private var pendingPeakGpuPower: Double = 0
    private var pendingPeakSystemPower: Double = 0

    // Batched DB writes — accumulate samples in memory, flush periodically
    private var pendingDBSamples: [BenchmarkSample] = []
    private let dbFlushInterval: TimeInterval = 5.0
    private var lastDBFlush: Date = .distantPast

    private var backendSubscriptions: [AnyCancellable] = []

    // MARK: - Initialization

    init(
        inferenceService: InferenceService,
        metricsService: MetricsService,
        databaseManager: DatabaseManager
    ) {
        self.inferenceService = inferenceService
        self.metricsService = metricsService
        self.databaseManager = databaseManager

        // Initialize from current backend
        self.selectedBackend = inferenceService.currentBackend

        setupMetricsSubscription()
        setupBackendSubscription()
    }

    private func setupBackendSubscription() {
        // Observe changes to inferenceService's currentBackend
        inferenceService.$currentBackend
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newBackend in
                guard let self = self else { return }
                if self.selectedBackend != newBackend {
                    self.selectedBackend = newBackend
                    Task {
                        await self.loadModels()
                    }
                }
            }
            .store(in: &backendSubscriptions)

        // Observe changes to the selected OpenAI config (switching between
        // two OpenAI-compatible backends keeps currentBackend == .openai,
        // so we need a separate subscription to detect config changes)
        inferenceService.$currentOpenAIConfig
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self, self.selectedBackend == .openai else { return }
                Task {
                    await self.loadModels()
                }
            }
            .store(in: &backendSubscriptions)
    }

    // MARK: - Public Methods

    /// Load available models from current backend
    func loadModels() async {
        // Refresh models from all backends first
        await inferenceService.refreshAllModels()

        // Sync selected backend with inference service's current backend
        selectedBackend = inferenceService.currentBackend

        // Get models for current backend (properly filters by OpenAI config ID if applicable)
        availableModels = inferenceService.modelsForCurrentBackend()

        // If switching backends and current model isn't available, select first available
        if selectedModel == nil || !availableModels.contains(where: { $0.id == selectedModel?.id }) {
            selectedModel = availableModels.first
        }

        // Check backend health
        if availableModels.isEmpty {
            let health: BackendHealth?
            if selectedBackend == .openai, let configId = inferenceService.currentOpenAIConfig?.id {
                health = inferenceService.openAIBackendHealth[configId]
            } else {
                health = inferenceService.backendHealth[selectedBackend]
            }
            if health?.isRunning != true {
                self.error = .backendNotRunning(backend: selectedBackend.rawValue)
            }
        }
    }

    /// Start a benchmark session
    func startBenchmark() {
        guard !isRunning else { return }
        guard let model = selectedModel else {
            error = .modelLoadFailed(modelId: "none", reason: "No model selected")
            return
        }

        // Reset state
        responseText = ""
        tokensGenerated = 0
        currentTokensPerSecond = 0
        peakTokensPerSecond = 0
        timeToFirstToken = nil
        currentPeakMemory = 0
        modelMemoryTotal = 0
        modelMemoryGPU = 0
        modelMemoryCPU = 0
        avgGpuPower = 0
        peakGpuPower = 0
        avgSystemPower = 0
        peakSystemPower = 0
        elapsedTime = 0
        debugState.reset()
        error = nil
        currentSamplesInternal = []
        chartStore.reset()

        // Reset buffers
        textBuffer = ""
        pendingTokenCount = 0
        pendingTps = 0
        pendingPeakTps = 0
        gpuPowerSum = 0
        systemPowerSum = 0
        powerSampleCount = 0
        pendingPeakGpuPower = 0
        pendingPeakSystemPower = 0
        lastChartUpdate = .distantPast
        pendingDBSamples = []
        lastDBFlush = .distantPast

        // Create session with connection name
        var session = BenchmarkSession(
            modelId: model.id,
            modelName: model.name,
            backend: selectedBackend,
            connectionName: connectionName,
            prompt: promptText
        )

        isRunning = true
        benchmarkStartTime = Date()
        currentSession = session

        // Start metrics collection
        metricsService.startCollecting()

        // Auto-detect backend process by port (more reliable than path matching)
        if !isCustomProcessActive {
            Task {
                if let port = extractPort(from: connectionURL) {
                    if let detected = await metricsService.autoDetectByPort(port) {
                        Log.benchmark.info("Port \(port) → \(detected.name) (PID \(detected.pid), \(Formatters.bytes(detected.memoryBytes)))")
                    }
                }
            }
        }

        // Start elapsed timer
        startElapsedTimer()

        // Start UI update timer for batched updates
        startUIUpdateTimer()

        // Set the backend on inference service
        inferenceService.setBackend(selectedBackend)

        // Run inference
        benchmarkTask = Task {
            do {
                // Save session to get ID
                try await databaseManager.queue.write { db in
                    try session.insert(db)
                }
                currentSession = session

                // Now start proper sample collection with session ID
                if let sessionId = session.id {
                    startSampleCollection(sessionId: sessionId)
                }

                let request = InferenceRequest(
                    model: model.id,
                    prompt: promptText,
                    systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
                    maxTokens: maxTokens,
                    temperature: temperature,
                    topP: topP
                )

                // Initialize debug state
                self.debugState.backendType = self.selectedBackend
                self.debugState.endpointURL = self.connectionURL
                self.debugState.modelId = model.id
                self.debugState.requestTimestamp = Date()
                self.debugState.promptSnippet = String(self.promptText.prefix(200))
                self.debugState.systemPrompt = self.systemPrompt.isEmpty ? nil : self.systemPrompt
                self.debugState.maxTokens = self.maxTokens
                self.debugState.temperature = self.temperature
                self.debugState.topP = self.topP
                self.debugState.phase = .connecting
                self.debugState.requestJSON = DebugInspectorState.buildRequestJSON(
                    backend: self.selectedBackend, model: model.id, prompt: self.promptText,
                    systemPrompt: self.systemPrompt.isEmpty ? nil : self.systemPrompt,
                    maxTokens: self.maxTokens, temperature: self.temperature, topP: self.topP
                )

                var stats: InferenceStats?
                var tokenCount = 0
                var debugChunkCount = 0
                let startTime = Date()
                var firstTokenTime: Date?
                var lastSampleTime = startTime
                var lastSampleTokens = 0
                let instantaneousSampleInterval: TimeInterval = 0.25  // Calculate instantaneous rate every 250ms

                for try await chunk in inferenceService.generate(request: request) {
                    if Task.isCancelled { break }

                    // Track time to first token (update Published immediately - this is a one-time event)
                    if firstTokenTime == nil && !chunk.text.isEmpty {
                        firstTokenTime = Date()
                        timeToFirstToken = firstTokenTime!.timeIntervalSince(startTime)
                        self.debugState.firstChunkAt = firstTokenTime

                        // Fetch model memory now that model is loaded
                        await self.fetchModelMemory()
                    }

                    // Buffer text and stats (don't update @Published on every token)
                    textBuffer += chunk.text
                    tokenCount += 1
                    debugChunkCount += 1
                    self.debugState.chunksReceived = debugChunkCount
                    self.debugState.bytesReceived += chunk.text.utf8.count
                    self.debugState.lastChunkAt = Date()
                    self.debugState.phase = .streaming

                    let now = Date()
                    let totalElapsed = now.timeIntervalSince(startTime)

                    // Calculate cumulative average tok/s (buffer it)
                    if totalElapsed > 0 {
                        pendingTps = Double(tokenCount) / totalElapsed
                    }

                    // Calculate instantaneous tok/s for peak tracking
                    let sampleElapsed = now.timeIntervalSince(lastSampleTime)
                    if sampleElapsed >= instantaneousSampleInterval {
                        let tokensDelta = tokenCount - lastSampleTokens
                        let instantaneousTps = Double(tokensDelta) / sampleElapsed
                        pendingPeakTps = max(pendingPeakTps, instantaneousTps)
                        lastSampleTime = now
                        lastSampleTokens = tokenCount
                    }

                    // Update pending values for UI timer to flush
                    pendingTokenCount = tokenCount

                    if chunk.done, let chunkStats = chunk.stats {
                        stats = chunkStats
                    }
                }

                // Final flush of any remaining buffered content
                flushUIUpdates()

                // Calculate TTFT
                let ttft: TimeInterval? = firstTokenTime.map { $0.timeIntervalSince(startTime) }

                // Compute power summary from collected samples
                let powerSummary = BenchmarkSample.computePowerSummary(from: self.currentSamplesInternal)
                let backendName = self.metricsService.latestMetrics?.backendProcessName

                // Complete session
                if let finalStats = stats {
                    session.complete(
                        with: finalStats,
                        response: responseText,
                        timeToFirstToken: ttft,
                        peakMemoryBytes: currentPeakMemory > 0 ? currentPeakMemory : nil,
                        powerSummary: powerSummary,
                        backendProcessName: backendName
                    )
                } else {
                    // Create stats from our tracking
                    let duration = Date().timeIntervalSince(startTime)
                    let manualStats = InferenceStats(
                        totalTokens: tokenCount,
                        promptTokens: 0,
                        completionTokens: tokenCount,
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
                        peakMemoryBytes: currentPeakMemory > 0 ? currentPeakMemory : nil,
                        powerSummary: powerSummary,
                        backendProcessName: backendName
                    )
                }

                // Update session in database
                try await databaseManager.queue.write { db in
                    try session.update(db)
                }

                currentSession = session
                self.debugState.phase = .complete
                self.debugState.completedAt = Date()
                if let finalStats = stats {
                    self.debugState.finalTokensPerSecond = finalStats.tokensPerSecond
                    self.debugState.finalTotalTokens = finalStats.totalTokens
                }
                await finishBenchmark()

            } catch is CancellationError {
                session.cancel()
                try? await databaseManager.queue.write { db in
                    try session.update(db)
                }
                currentSession = session
                await finishBenchmark()

            } catch {
                session.fail()
                try? await databaseManager.queue.write { db in
                    try session.update(db)
                }
                currentSession = session
                self.debugState.phase = .error
                self.debugState.errorMessage = error.localizedDescription
                self.debugState.completedAt = Date()
                self.error = .inferenceTimeout(after: elapsedTime)
                await finishBenchmark()
            }
        }
    }

    /// Stop the current benchmark
    func stopBenchmark() {
        benchmarkTask?.cancel()
        benchmarkTask = nil
    }

    /// Load recent benchmark sessions from database
    func loadRecentSessions() async {
        do {
            recentSessions = try await databaseManager.queue.read { db in
                try BenchmarkSession.fetchRecent(db: db, limit: 20)
            }
        } catch {
            Log.benchmark.error("Failed to load recent sessions: \(error.localizedDescription)")
        }
    }

    /// Load samples for a specific session
    func loadSamples(for session: BenchmarkSession) async -> [BenchmarkSample] {
        guard let sessionId = session.id else { return [] }
        do {
            return try await databaseManager.queue.read { db in
                try BenchmarkSample.fetchForSession(db: db, sessionId: sessionId)
            }
        } catch {
            Log.benchmark.error("Failed to load samples: \(error.localizedDescription)")
            return []
        }
    }

    /// Delete a session
    func deleteSession(_ session: BenchmarkSession) async {
        guard let sessionId = session.id else { return }
        do {
            try await databaseManager.queue.write { db in
                // Delete samples first
                try BenchmarkSample.deleteForSession(db: db, sessionId: sessionId)
                // Delete session
                try session.delete(db)
            }
            await loadRecentSessions()
        } catch {
            Log.benchmark.error("Failed to delete session: \(error.localizedDescription)")
        }
    }

    /// Delete all sessions
    func deleteAllSessions() async {
        do {
            try await databaseManager.queue.write { db in
                // Delete all samples
                try db.execute(sql: "DELETE FROM benchmark_sample")
                // Delete all sessions
                try db.execute(sql: "DELETE FROM benchmark_session")
            }
            recentSessions = []
        } catch {
            Log.benchmark.error("Failed to delete all sessions: \(error.localizedDescription)")
        }
    }

    /// Mark a session as cancelled
    func markSessionCancelled(_ session: BenchmarkSession) async {
        guard let sessionId = session.id else { return }
        do {
            try await databaseManager.queue.write { db in
                try db.execute(
                    sql: "UPDATE benchmark_session SET status = ?, ended_at = ? WHERE id = ?",
                    arguments: [BenchmarkStatus.cancelled.rawValue, Date(), sessionId]
                )
            }
            await loadRecentSessions()
        } catch {
            Log.benchmark.error("Failed to mark session as cancelled: \(error.localizedDescription)")
        }
    }

    /// Clean up all running sessions (mark as cancelled)
    func cleanupRunningSessions() async {
        do {
            try await databaseManager.queue.write { db in
                try db.execute(
                    sql: "UPDATE benchmark_session SET status = ?, ended_at = ? WHERE status = ?",
                    arguments: [BenchmarkStatus.cancelled.rawValue, Date(), BenchmarkStatus.running.rawValue]
                )
            }
            await loadRecentSessions()
        } catch {
            Log.benchmark.error("Failed to cleanup running sessions: \(error.localizedDescription)")
        }
    }

    // MARK: - Process Selection

    /// Refresh the list of candidate processes for the picker
    func refreshProcessList() async {
        candidateProcesses = await metricsService.listCandidateProcesses()
    }

    /// Set a custom process to monitor
    func selectCustomProcess(_ process: ProcessCandidate) {
        metricsService.setCustomProcess(pid: process.pid, name: process.name)
        isCustomProcessActive = true
    }

    /// Clear custom process and return to auto-detection
    func clearCustomProcess() {
        metricsService.clearCustomProcess()
        isCustomProcessActive = false
    }

    /// Get chart data for current samples (uses cached data for performance)
    func getChartData() -> BenchmarkChartData {
        chartStore.chartData
    }

    /// Get the current samples (for history/export)
    var currentSamples: [BenchmarkSample] {
        currentSamplesInternal
    }

    // MARK: - Private Methods

    private func setupMetricsSubscription() {
        metricsSubscription = metricsService.$currentMetrics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] metrics in
                self?.currentMetrics = metrics
            }
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        // Update at 1Hz — display only shows seconds, no need for 10Hz updates
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let startTime = self.benchmarkStartTime else { return }
                self.elapsedTime = Date().timeIntervalSince(startTime)
            }
        }
    }

    private func startUIUpdateTimer() {
        uiUpdateTimer?.invalidate()
        let interval = streamResponse ? uiUpdateInterval : 1.0
        uiUpdateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushUIUpdates()
            }
        }
    }

    /// Flush buffered updates to @Published properties (called at fixed interval)
    private func flushUIUpdates() {
        // Only flush text if streaming is enabled (otherwise accumulate in buffer until completion)
        if streamResponse && !textBuffer.isEmpty {
            responseText += textBuffer
            textBuffer = ""
        }

        // Numeric updates are cheap — always flush
        if pendingTokenCount != tokensGenerated {
            tokensGenerated = pendingTokenCount
        }
        if pendingTps != currentTokensPerSecond {
            currentTokensPerSecond = pendingTps
        }
        if pendingPeakTps != peakTokensPerSecond {
            peakTokensPerSecond = pendingPeakTps
        }

        // Power running stats
        if powerSampleCount > 0 {
            let newAvgGpu = gpuPowerSum / Double(powerSampleCount)
            if newAvgGpu != avgGpuPower { avgGpuPower = newAvgGpu }
            if pendingPeakGpuPower != peakGpuPower { peakGpuPower = pendingPeakGpuPower }

            let newAvgSys = systemPowerSum / Double(powerSampleCount)
            if newAvgSys != avgSystemPower { avgSystemPower = newAvgSys }
            if pendingPeakSystemPower != peakSystemPower { peakSystemPower = pendingPeakSystemPower }
        }
    }

    /// Fetch model memory breakdown from Ollama /api/ps
    private func fetchModelMemory() async {
        guard selectedBackend == .ollama else { return }

        let ollamaClient = inferenceService.ollamaClient

        do {
            let runningModels = try await ollamaClient.listRunningModels()

            // Find the current model (or just take the first one if only one loaded)
            if let running = runningModels.first(where: { $0.name == selectedModel?.id }) ?? runningModels.first {
                modelMemoryTotal = running.sizeBytes
                modelMemoryGPU = running.sizeVRAM
                modelMemoryCPU = running.sizeBytes - running.sizeVRAM
            }
        } catch {
            Log.benchmark.warning("Failed to fetch model memory: \(error.localizedDescription)")
        }
    }

    private func startSampleCollection(sessionId: Int64) {
        sampleTimer?.invalidate()

        sampleTimer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.collectSample(sessionId: sessionId)
            }
        }
    }

    private func collectSample(sessionId: Int64) async {
        guard isRunning else { return }

        // Read cached metrics — NO system calls, just a property read
        guard let metrics = metricsService.latestMetrics else { return }

        // Process tree memory (from ProcessMonitor) already includes model memory
        // in RSS — no need to add modelMemoryTotal from /api/ps on top.
        let snapshotMetrics = SystemMetrics(
            timestamp: Date(),
            gpuUtilization: metrics.gpuUtilization,
            cpuUtilization: metrics.cpuUtilization,
            memoryUsedBytes: metrics.memoryUsedBytes,
            memoryTotalBytes: metrics.memoryTotalBytes,
            thermalState: metrics.thermalState,
            gpuPowerWatts: metrics.gpuPowerWatts,
            cpuPowerWatts: metrics.cpuPowerWatts,
            anePowerWatts: metrics.anePowerWatts,
            dramPowerWatts: metrics.dramPowerWatts,
            systemPowerWatts: metrics.systemPowerWatts,
            gpuFrequencyMHz: metrics.gpuFrequencyMHz,
            backendProcessMemoryBytes: metrics.backendProcessMemoryBytes,
            backendProcessCPUPercent: metrics.backendProcessCPUPercent,
            backendProcessName: metrics.backendProcessName
        )

        var sample = BenchmarkSample(
            sessionId: sessionId,
            metrics: snapshotMetrics,
            tokensGenerated: pendingTokenCount,
            cumulativeTokensPerSecond: pendingTps
        )

        // Assign a local ID for in-memory tracking (DB will assign real ID on flush)
        currentSamplesInternal.append(sample)
        pendingDBSamples.append(sample)

        // Track peak backend process memory
        if metrics.memoryUsedBytes > currentPeakMemory {
            currentPeakMemory = metrics.memoryUsedBytes
        }

        // Accumulate power stats for running avg/peak
        if let gpuW = metrics.gpuPowerWatts, gpuW > 0 {
            gpuPowerSum += gpuW
            pendingPeakGpuPower = max(pendingPeakGpuPower, gpuW)
        }
        if let sysW = metrics.systemPowerWatts, sysW > 0 {
            systemPowerSum += sysW
            pendingPeakSystemPower = max(pendingPeakSystemPower, sysW)
        }
        if (metrics.gpuPowerWatts ?? 0) > 0 || (metrics.systemPowerWatts ?? 0) > 0 {
            powerSampleCount += 1
        }

        // Flush to database periodically (every 5s) instead of on every sample
        let now = Date()
        if now.timeIntervalSince(lastDBFlush) >= dbFlushInterval {
            await flushSamplesToDatabase()
        }

        // Update chart data at throttled rate
        if now.timeIntervalSince(lastChartUpdate) >= chartUpdateInterval {
            lastChartUpdate = now

            let samples = currentSamplesInternal
            let maxPoints = maxChartDataPoints
            Task.detached(priority: .utility) {
                let samplesToUse: [BenchmarkSample]
                if samples.count > maxPoints {
                    let stride = samples.count / maxPoints
                    samplesToUse = samples.enumerated().compactMap { index, sample in
                        index % stride == 0 || index == samples.count - 1 ? sample : nil
                    }
                } else {
                    samplesToUse = samples
                }

                let newChartData = BenchmarkSample.chartData(from: samplesToUse)

                await MainActor.run {
                    self.chartStore.update(newChartData)
                }
            }
        }
    }

    /// Flush accumulated samples to database in a single batch write
    private func flushSamplesToDatabase() async {
        guard !pendingDBSamples.isEmpty else { return }
        let samplesToWrite = pendingDBSamples
        pendingDBSamples = []
        lastDBFlush = Date()

        // Write all pending samples in one transaction — off the hot path
        Task.detached(priority: .utility) { [databaseManager] in
            do {
                try await databaseManager.queue.write { db in
                    for var sample in samplesToWrite {
                        try sample.insert(db)
                    }
                }
            } catch {
                Log.benchmark.error("Failed to flush samples to database: \(error.localizedDescription)")
            }
        }
    }

    private func finishBenchmark() async {
        isRunning = false
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        sampleTimer?.invalidate()
        sampleTimer = nil
        uiUpdateTimer?.invalidate()
        uiUpdateTimer = nil
        benchmarkStartTime = nil

        // Dump any suppressed text before final flush
        if !streamResponse && !textBuffer.isEmpty {
            responseText += textBuffer
            textBuffer = ""
        }

        // Final flush of any remaining buffered content
        flushUIUpdates()

        // Flush any remaining samples to database before finishing
        await flushSamplesToDatabase()

        // Final chart update with all collected samples (on background thread)
        if !currentSamplesInternal.isEmpty {
            let samples = currentSamplesInternal
            Task.detached(priority: .userInitiated) {
                let newChartData = BenchmarkSample.chartData(from: samples)
                await MainActor.run {
                    self.chartStore.update(newChartData)
                }
            }
        }

        metricsService.stopCollecting()

        // Clear port-detected process (unless user manually pinned one)
        if !isCustomProcessActive {
            metricsService.clearCustomProcess()
        }

        // Reload recent sessions
        await loadRecentSessions()
    }

    /// Extract TCP port from a URL string (e.g. "http://localhost:11434" → 11434)
    private func extractPort(from urlString: String) -> UInt16? {
        if let url = URL(string: urlString), let port = url.port {
            return UInt16(port)
        }
        // Common defaults if no explicit port
        if urlString.hasPrefix("https") { return 443 }
        if urlString.hasPrefix("http") { return 80 }
        return nil
    }

    // Peak memory is now tracked from backend process tree metrics in collectSample(),
    // not from the app's own mach_task_self_ (which was only a few hundred MB).
}

// MARK: - Convenience Extensions

extension BenchmarkViewModel {
    /// Formatted elapsed time string
    var formattedElapsedTime: String {
        Formatters.duration(elapsedTime)
    }

    /// Formatted tokens per second (average)
    var formattedTokensPerSecond: String {
        // Use final stats if completed, otherwise use real-time
        if let session = currentSession, session.status == .completed, let tps = session.tokensPerSecond {
            return Formatters.tokensPerSecond(tps)
        }
        return Formatters.tokensPerSecond(currentTokensPerSecond)
    }

    /// Formatted peak tokens per second
    var formattedPeakTokensPerSecond: String {
        Formatters.tokensPerSecond(peakTokensPerSecond)
    }

    /// Formatted process tree memory (includes model + server + children)
    var formattedMemoryUsage: String? {
        guard let metrics = currentMetrics else { return nil }
        return Formatters.bytes(metrics.memoryUsedBytes)
    }

    /// Formatted total process memory (process tree RSS — includes model in memory)
    var formattedTotalMemory: String {
        let processMemory = currentMetrics?.memoryUsedBytes ?? 0
        if processMemory > 0 {
            return Formatters.bytes(processMemory)
        }
        return "—"
    }

    /// Formatted model memory with GPU/CPU breakdown
    var formattedModelMemory: String {
        guard modelMemoryTotal > 0 else { return "—" }
        return Formatters.bytes(modelMemoryTotal)
    }

    /// Formatted GPU memory portion
    var formattedGPUMemory: String {
        guard modelMemoryGPU > 0 else { return "—" }
        return Formatters.bytes(modelMemoryGPU)
    }

    /// Formatted CPU memory portion
    var formattedCPUMemory: String {
        guard modelMemoryCPU > 0 else { return "—" }
        return Formatters.bytes(modelMemoryCPU)
    }

    /// GPU memory percentage of total model memory
    var gpuMemoryPercent: Double {
        guard modelMemoryTotal > 0 else { return 0 }
        return Double(modelMemoryGPU) / Double(modelMemoryTotal)
    }

    /// Whether model memory info is available
    var hasModelMemory: Bool {
        modelMemoryTotal > 0
    }

    /// GPU utilization percentage
    var gpuUtilizationPercent: Double {
        (currentMetrics?.gpuUtilization ?? 0) * 100
    }

    /// CPU utilization percentage
    var cpuUtilizationPercent: Double {
        (currentMetrics?.cpuUtilization ?? 0) * 100
    }

    /// Whether hardware metrics are available
    var hasHardwareMetrics: Bool {
        metricsService.isIOReportAvailable
    }

    /// Whether power metrics (IOReport subscription) are available
    var hasPowerMetrics: Bool {
        metricsService.isPowerMetricsAvailable
    }

    /// Average GPU power formatted (running avg during benchmark, final after)
    var avgGPUPowerFormatted: String {
        if let session = currentSession, session.status == .completed,
           let avg = session.avgGpuPowerWatts {
            return Formatters.watts(avg)
        }
        guard avgGpuPower > 0 else { return "—" }
        return Formatters.watts(avgGpuPower)
    }

    /// Peak GPU power formatted
    var peakGPUPowerFormatted: String {
        if let session = currentSession, session.status == .completed,
           let peak = session.peakGpuPowerWatts {
            return Formatters.watts(peak)
        }
        guard peakGpuPower > 0 else { return "—" }
        return Formatters.watts(peakGpuPower)
    }

    /// Average system power formatted (running avg during benchmark, final after)
    var avgSystemPowerFormatted: String {
        if let session = currentSession, session.status == .completed,
           let avg = session.avgSystemPowerWatts {
            return Formatters.watts(avg)
        }
        guard avgSystemPower > 0 else { return "—" }
        return Formatters.watts(avgSystemPower)
    }

    /// Peak system power formatted
    var peakSystemPowerFormatted: String {
        if let session = currentSession, session.status == .completed,
           let peak = session.peakSystemPowerWatts {
            return Formatters.watts(peak)
        }
        guard peakSystemPower > 0 else { return "—" }
        return Formatters.watts(peakSystemPower)
    }

    /// Current GPU frequency formatted
    var currentGPUFrequencyFormatted: String {
        guard let freq = currentMetrics?.gpuFrequencyMHz, freq > 0 else { return "—" }
        return String(format: "%.0f MHz", freq)
    }

    /// Watts per token formatted (avg system power / avg tok/s)
    var currentWattsPerTokenFormatted: String {
        if let session = currentSession, session.status == .completed,
           let wpt = session.avgWattsPerToken {
            return String(format: "%.2f W/tok", wpt)
        }
        guard avgSystemPower > 0, currentTokensPerSecond > 0 else { return "—" }
        let wpt = avgSystemPower / currentTokensPerSecond
        return String(format: "%.2f W/tok", wpt)
    }

    /// Formatted process memory (process tree RSS — includes model + server + children)
    var formattedBackendMemory: String {
        if let mem = currentMetrics?.backendProcessMemoryBytes, mem > 0 {
            return Formatters.bytes(mem)
        }
        return "—"
    }

    /// Backend process name (from ProcessMonitor)
    var currentBackendProcessName: String? {
        currentMetrics?.backendProcessName
    }
}
