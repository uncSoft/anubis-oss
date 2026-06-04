//
//  BenchmarkViewModel.swift
//  anubis
//
//  Created on 2026-01-25.
//

import SwiftUI
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

/// Isolated observable for streaming response text.
/// Prevents metric card @Published updates from triggering text view re-evaluation.
@MainActor
final class ResponseTextStore: ObservableObject {
    @Published private(set) var text: String = ""

    func append(_ delta: String) {
        text += delta
    }

    func set(_ value: String) {
        text = value
    }

    func reset() {
        text = ""
    }
}

// MARK: - Per-Core Chart Data (live-only)

struct CoreTimeSeries {
    let coreIndex: Int
    let coreType: CoreType
    var samples: [(Date, Double)]  // utilization 0–100%

    static let maxSamples = 60
}

struct PerCoreChartData {
    var cores: [Int: CoreTimeSeries]  // keyed by coreIndex

    mutating func append(snapshot: [CoreUtilization], at date: Date) {
        for core in snapshot {
            var series = cores[core.coreIndex] ?? CoreTimeSeries(
                coreIndex: core.coreIndex,
                coreType: core.coreType,
                samples: []
            )
            series.samples.append((date, core.utilization * 100))
            if series.samples.count > CoreTimeSeries.maxSamples {
                series.samples.removeFirst()
            }
            cores[core.coreIndex] = series
        }
    }

    static let empty = PerCoreChartData(cores: [:])
}

// MARK: - GPU Detail Data (live-only)

struct GPUMetricTimeSeries {
    var samples: [(Date, Double)] = []
    static let maxSamples = 60

    mutating func append(_ value: Double, at date: Date) {
        samples.append((date, value))
        if samples.count > Self.maxSamples {
            samples.removeFirst()
        }
    }
}

struct GPUDetailData {
    var utilization = GPUMetricTimeSeries()
    var frequencyMHz = GPUMetricTimeSeries()
    var powerWatts = GPUMetricTimeSeries()
    var latestPStateDistribution: [GPUPStateResidency] = []

    mutating func append(metrics: SystemMetrics, at date: Date) {
        utilization.append(metrics.gpuUtilization * 100, at: date)
        if let freq = metrics.gpuFrequencyMHz {
            frequencyMHz.append(freq, at: date)
        }
        if let power = metrics.gpuPowerWatts {
            powerWatts.append(power, at: date)
        }
        if let pState = metrics.gpuPStateDistribution {
            latestPStateDistribution = pState
        }
    }

    static let empty = GPUDetailData()
}

/// ViewModel for the Benchmark module
/// Manages benchmark sessions, coordinates inference with metrics collection
@MainActor
final class BenchmarkViewModel: ObservableObject {
    // MARK: - Published State

    /// Current benchmark session (if running or just completed). When
    /// running as part of a run group, this is the current repetition.
    @Published private(set) var currentSession: BenchmarkSession?

    /// Whether a benchmark is currently running (single or group).
    @Published private(set) var isRunning = false

    // MARK: - Leaderboard submission state
    //
    // Drives the toolbar "Upload to Leaderboard" pill's state machine:
    //   idle (nothing to do) → uploading → submitted ✓  OR  failed ⚠
    // Also surfaces auto-submit results without nagging the user.

    /// Tracks whether the rep most recently completed in this app
    /// session has already been uploaded to the leaderboard (either by
    /// the user clicking Upload, or by the auto-submit path). Reset on
    /// every new `currentSession`.
    @Published private(set) var currentSessionLeaderboardSubmitted: Bool = false

    /// True while an upload (manual or auto) is in flight. The pill
    /// shows a progress indicator.
    @Published private(set) var leaderboardSubmissionInProgress: Bool = false

    /// Last auto-submit failure, surfaced in the pill's tooltip so the
    /// user knows submission isn't silently rotting. Cleared on the
    /// next successful submission.
    @Published private(set) var lastLeaderboardSubmissionError: String?

    // MARK: - Run Group (Phase 1.2)

    /// Target number of repetitions for a benchmark group. Default 1
    /// (single-run, no group object created). Values > 1 create a
    /// BenchmarkRunGroup, run N sessions sequentially, and aggregate
    /// stats as mean ± 95% bootstrap CI.
    @Published var repetitions: Int = 1

    /// Per-rep seed strategy. `random` (default) generates a fresh seed
    /// per rep so the CI captures both hardware and sampler noise;
    /// `fixed` reuses `fixedSeed` for byte-identical output across reps
    /// and an isolated hardware-only CI.
    @Published var seedStrategy: SeedStrategy = .random

    /// Used only when `seedStrategy == .fixed`.
    @Published var fixedSeed: Int64 = 42

    /// Current run group (nil for single-run benchmarks).
    @Published private(set) var currentRunGroup: BenchmarkRunGroup?

    /// 1-based index of the current repetition within a group;
    /// 0 means not currently inside a group.
    @Published private(set) var currentRepetitionIndex: Int = 0

    /// View-mode for the post-completion dashboard. When the user just
    /// finished a multi-rep group, do the metric cards + detail stats
    /// show the *group mean* across all reps, or just the *last rep's*
    /// numbers? Default to .fullGroup so the cards agree with the
    /// summary-card headline; toggle exposed on the summary card.
    enum GroupViewMode: String, CaseIterable {
        case fullGroup    // mean across all reps in the group
        case lastRep      // last rep's session values (legacy behavior)
    }
    @Published var groupViewMode: GroupViewMode = .fullGroup

    /// Current real-time metrics during benchmark.
    /// Demoted from @Published — coalesced into notifyMetricsBatchChanged()
    /// alongside latestPerCoreSnapshot, perCoreData, and debugState so that
    /// per-sample subscription updates fire ONE objectWillChange.send()
    /// per tick instead of 3-4. In group streaming this is further
    /// throttled to ~1Hz to keep MainActor free for text flush.
    private(set) var currentMetrics: SystemMetrics?

    /// Accumulated response text (internal only — views observe responseTextStore instead)
    private var responseText = ""

    /// When false, suppress response text rendering during benchmark for minimal CPU interference.
    /// Text is still accumulated internally and shown on completion.
    @Published var streamResponse = true

    /// Whether to show live charts during benchmark
    @Published var showLiveCharts = true

    /// Current tokens per second (real-time average)
    // Per-sample-tick "live stats". Bundled into one notification per
    // collectSample call rather than 8 separate @Published mutations,
    // which were causing a Core Animation transaction storm — see the
    // 2026-05-22 hang sample showing 460 frames in CA::Layer::display_
    // if_needed driven by repeated @Published cascades on the VM.
    // Manual objectWillChange.send() is called once per batch via
    // notifyLiveStatsChanged().
    private(set) var currentTokensPerSecond: Double = 0

    /// Peak tokens per second observed during benchmark
    private(set) var peakTokensPerSecond: Double = 0

    /// Time to first token (live tracking)
    @Published private(set) var timeToFirstToken: TimeInterval?

    /// Prefill (input) tokens per second, populated when stats arrive at end of run.
    @Published private(set) var prefillTokensPerSecond: Double?

    /// Peak memory usage during benchmark
    private(set) var currentPeakMemory: Int64 = 0

    /// Model memory info (from Ollama /api/ps)
    @Published private(set) var modelMemoryTotal: Int64 = 0
    @Published private(set) var modelMemoryGPU: Int64 = 0
    @Published private(set) var modelMemoryCPU: Int64 = 0

    /// Running average GPU power during benchmark
    private(set) var avgGpuPower: Double = 0

    /// Peak GPU power observed during benchmark
    private(set) var peakGpuPower: Double = 0

    /// Running average system power during benchmark
    private(set) var avgSystemPower: Double = 0

    /// Peak system power observed during benchmark
    private(set) var peakSystemPower: Double = 0

    /// Total tokens generated so far
    private(set) var tokensGenerated = 0

    /// Elapsed time since benchmark start
    @Published private(set) var elapsedTime: TimeInterval = 0

    /// Available models for selection
    @Published private(set) var availableModels: [ModelInfo] = []

    /// Selected model for benchmark
    @Published var selectedModel: ModelInfo? {
        didSet {
            // Persist so the next launch restores the same model (scoped to
            // the persisted backend — see PersistedModelSelection).
            PersistedModelSelection.save(selectedModel?.name)
        }
    }

    /// Selected backend (synced with inferenceService — initial value is
    /// read from inferenceService in init, no longer hardcoded to .ollama).
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
        case .appleIntelligence:
            return "Apple Intelligence"
        }
    }

    /// True when the active backend is the built-in oMLX stock configuration.
    /// Used to apply oMLX-specific verification — if the user points this at a
    /// server that isn't actually oMLX, we warn rather than silently trust it.
    var isBuiltInOMLXBackend: Bool {
        selectedBackend == .openai &&
        inferenceService.currentOpenAIConfig?.id == BackendConfiguration.defaultOMLX.id
    }

    /// True when the connected server has positively identified itself as oMLX.
    /// Two independent signals, either of which suffices:
    ///  - run-time: the last run returned oMLX's metric signature (the
    ///    extended `usage` block) — proof the server actually produced it.
    ///  - connect-time: its `/v1/models` listing stamps `owned_by: omlx`.
    /// Guards against another OpenAI-compatible server on the oMLX port being
    /// mistaken for the real thing.
    var isVerifiedOMLX: Bool {
        if currentSession?.serverMetricsJSON != nil { return true }
        if let owner = selectedModel?.ownedBy?.lowercased(), owner.contains("omlx") { return true }
        return false
    }

    /// Whether the current backend exposes a thinking toggle. Ollama uses the
    /// `think` request field; oMLX uses `chat_template_kwargs.enable_thinking`.
    /// Other OpenAI-compatible servers (LM Studio, vLLM, plain mlx-lm) don't,
    /// so the picker stays hidden and the mode stays Auto for them.
    var supportsThinkingToggle: Bool {
        selectedBackend == .ollama || isBuiltInOMLXBackend || isVerifiedOMLX
    }

    /// Whether the selected model can be ejected (unloaded) from here. Both
    /// Ollama (keep_alive: 0) and oMLX (admin unload) support it.
    var canEjectSelectedModel: Bool {
        guard selectedModel != nil else { return false }
        if selectedBackend == .ollama { return true }
        return isBuiltInOMLXBackend || isVerifiedOMLX
    }

    @Published var isEjectingModel = false
    /// Transient, non-error feedback for the eject button (e.g. the model was
    /// already unloaded). Auto-clears; shown as a caption near the picker.
    @Published var ejectNotice: String?

    /// Unload the selected model from the backend's memory (Ollama or oMLX).
    func ejectSelectedModel() async {
        guard canEjectSelectedModel, let model = selectedModel else { return }
        isEjectingModel = true
        ejectNotice = nil
        defer { isEjectingModel = false }
        do {
            if selectedBackend == .ollama {
                try await inferenceService.ollamaClient.unloadModel(model.id)
            } else if let configId = inferenceService.currentOpenAIConfig?.id,
                      let client = inferenceService.openAIClient(for: configId) {
                try await client.unloadModel(model.id)
            } else {
                return
            }
            showEjectNotice("Unloaded \(model.name) from memory.")
        } catch let e as OMLXAdminError where e.isBenignNotLoaded {
            // Not loaded == already in the desired state; not an error.
            showEjectNotice("\(model.name) wasn't loaded — nothing to unload.")
        } catch let e as OMLXAdminError {
            self.error = .backendMessage(e.errorDescription ?? "Failed to unload \(model.name).")
        } catch {
            self.error = .backendMessage("Failed to unload \(model.name): \(error.localizedDescription)")
        }
    }

    private func showEjectNotice(_ text: String) {
        ejectNotice = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self?.ejectNotice == text { self?.ejectNotice = nil }
        }
    }

    /// Active connection URL (resolved from backend + config)
    var connectionURL: String {
        switch selectedBackend {
        case .ollama:
            return inferenceService.configManager.ollamaConfig?.baseURL ?? "http://localhost:11434"
        case .openai:
            return inferenceService.currentOpenAIConfig?.baseURL ?? "—"
        case .appleIntelligence:
            return "on-device"
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

    /// Ollama-only: controls the `think` request parameter. Persisted across
    /// launches. `.auto` is the default — omits the field so the model uses
    /// its server-side default (older Ollama / non-thinking models reject the
    /// param outright). Explicit `.on` / `.off` forces the value.
    @Published var ollamaThinkMode: OllamaThinkMode = OllamaThinkMode(
        rawValue: UserDefaults.standard.string(forKey: "anubis.ollamaThinkMode") ?? ""
    ) ?? .auto {
        didSet {
            UserDefaults.standard.set(ollamaThinkMode.rawValue, forKey: "anubis.ollamaThinkMode")
        }
    }

    /// Debug inspector state — demoted from @Published, see
    /// notifyMetricsBatchChanged for the coalescing strategy.
    private(set) var debugState = DebugInspectorState()

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

    /// Per-core utilization data (live-only, not persisted).
    /// Demoted from @Published — see notifyMetricsBatchChanged.
    private(set) var perCoreData: PerCoreChartData = .empty

    /// Latest per-core snapshot for the inline grid.
    /// Demoted from @Published — see notifyMetricsBatchChanged.
    private(set) var latestPerCoreSnapshot: [CoreUtilization] = []

    /// GPU detail data for the GPU detail pop-out window.
    /// Demoted from @Published — see notifyMetricsBatchChanged.
    private(set) var gpuDetailData: GPUDetailData = .empty

    /// Latest GPU utilization for the inline GPU core grid.
    /// Demoted from @Published — see notifyMetricsBatchChanged.
    private(set) var latestGPUUtilization: Double = 0

    /// Response text lives in a separate observable so metric card @Published
    /// updates don't trigger NSTextView re-evaluation (the #1 streaming bottleneck).
    let responseTextStore = ResponseTextStore()

    // MARK: - Pull State

    @Published var showPullSheet = false
    @Published var isPulling = false
    @Published var pullModelName = ""
    @Published var pullStatus = ""
    @Published var pullProgress: Double = 0
    /// Holds the in-flight pull so Cancel can interrupt it.
    /// Cancelling this Task cascades through the AsyncThrowingStream
    /// in OllamaClient.pullModel (via continuation.onTermination)
    /// down to the URLSession.bytes read, which closes the HTTP
    /// connection and stops the download.
    private var pullTask: Task<Void, Never>?

    // MARK: - Browse Library State

    /// Sheet for the curated browse experience (separate from the
    /// existing "pull by typed name" sheet, so users have both
    /// flows: type-a-name OR browse).
    @Published var showBrowseLibrarySheet = false
    @Published private(set) var libraryEntries: [OllamaLibraryEntry] = []
    @Published private(set) var libraryLoading: Bool = false
    @Published private(set) var libraryError: String?
    @Published var librarySearchQuery: String = ""

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

    // MARK: - Auxiliary Windows

    /// References to spawned windows (kept alive while open)
    private(set) var historyWindow: NSWindow?
    private(set) var expandedMetricsWindow: NSWindow?
    private(set) var coreDetailWindow: NSWindow?
    private(set) var gpuDetailWindow: NSWindow?
    private var sessionDetailWindows: [Int64: NSWindow] = [:]

    // Sampling configuration
    private let sampleInterval: TimeInterval = 0.5   // Sample metrics at 2Hz (was 0.1s/10Hz — reduced to match MetricsService polling)
    private let uiUpdateInterval: TimeInterval = 0.1  // 10 FPS for smooth text streaming
    private let chartUpdateInterval: TimeInterval = 0.5  // Charts update at 2Hz (aligned with sample rate)
    private var lastChartUpdate: Date = .distantPast
    private let maxChartDataPoints = 250  // Limit chart points to keep rendering fast

    /// Timestamp of the last successfully-collected sample. Used by
    /// collectSample's throttle floor to collapse backed-up Tasks that
    /// would otherwise produce sub-400ms gaps and spike the chart's
    /// instantaneous-tok/s calculation. See [SPIKE BUG] notes.
    private var lastSampleCollectedAt: Date = .distantPast
    private let minimumSampleSpacing: TimeInterval = 0.4

    // Lock-protected stream buffers — written by Task.detached consumer, read by UI timer
    private struct StreamBuffers {
        var text: String = ""
        var tokenCount: Int = 0
        var peakTps: Double = 0
        var chunkCount: Int = 0
        var bytesReceived: Int = 0
        var firstTokenTime: Date? = nil
        var stats: InferenceStats? = nil
        // Stream start time — readers compute fresh tps as tokenCount / elapsed
        var startTime: Date = .distantPast
        // For instantaneous tok/s calculation
        var lastSampleTime: Date = .distantPast
        var lastSampleTokens: Int = 0
    }

    private let streamLock = OSAllocatedUnfairLock(initialState: StreamBuffers())
    private var consumeTask: Task<Void, Error>?

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

        // Reload chart data when the user flips the group view-mode
        // toggle. Initial value is skipped via dropFirst so this doesn't
        // fire at startup before any benchmark has run.
        $groupViewMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task { await self.reloadChartForCurrentViewMode() }
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
    private var didInitialLoad = false

    /// One-time load on first appearance. The VM now outlives the view (it's
    /// owned by AppState), so re-running this on every tab return would be
    /// wasteful and could reset the selected model mid-run — guard it.
    func loadInitialDataIfNeeded() async {
        guard !didInitialLoad else { return }
        didInitialLoad = true
        await loadModels()
        await loadRecentSessions()
    }

    func loadModels() async {
        // Clear any stale error (e.g. backend-not-running from a previous switch)
        error = nil

        // Refresh models from all backends first
        await inferenceService.refreshAllModels()

        // Sync selected backend with inference service's current backend
        selectedBackend = inferenceService.currentBackend

        // Get models for current backend (properly filters by OpenAI config ID if applicable)
        availableModels = inferenceService.modelsForCurrentBackend()

        // If the current model isn't in the new list, try to restore the
        // user's persisted last-used model name; fall back to the first one.
        if selectedModel == nil || !availableModels.contains(where: { $0.id == selectedModel?.id }) {
            if let persistedName = PersistedModelSelection.load(),
               let restored = availableModels.first(where: { $0.name == persistedName }) {
                selectedModel = restored
            } else {
                selectedModel = availableModels.first
            }
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

    /// Reset per-repetition state. Called at the top of every rep
    /// (both single-run and group runs) so each rep starts clean.
    private func resetPerRepState() {
        // Kill any in-flight sample timer from a previous rep. Timer.
        // invalidate() prevents future fires but does NOT cancel Tasks
        // already enqueued from a recent fire — those leftover Tasks
        // are handled by the sessionId-mismatch guard in collectSample.
        sampleTimer?.invalidate()
        sampleTimer = nil

        // Reset the per-rep throttle anchor so the first sample of the
        // next rep isn't blocked by the floor.
        lastSampleCollectedAt = .distantPast
        // Same for the metrics-batch notification throttle — first
        // sample of each rep should always notify.
        lastMetricsNotificationAt = .distantPast

        responseText = ""
        responseTextStore.reset()
        // Reset the live-stat fields without firing 8 separate cascades —
        // we'll emit one notification below covering the whole batch.
        tokensGenerated = 0
        currentTokensPerSecond = 0
        peakTokensPerSecond = 0
        timeToFirstToken = nil
        prefillTokensPerSecond = nil
        currentPeakMemory = 0
        modelMemoryTotal = 0
        modelMemoryGPU = 0
        modelMemoryCPU = 0
        avgGpuPower = 0
        peakGpuPower = 0
        avgSystemPower = 0
        peakSystemPower = 0
        elapsedTime = 0
        notifyLiveStatsChanged()
        debugState.reset()
        error = nil
        currentSamplesInternal = []
        chartStore.reset()
        perCoreData = .empty
        latestPerCoreSnapshot = []
        gpuDetailData = .empty

        streamLock.withLock { $0 = StreamBuffers() }
        gpuPowerSum = 0
        systemPowerSum = 0
        powerSampleCount = 0
        pendingPeakGpuPower = 0
        pendingPeakSystemPower = 0
        lastChartUpdate = .distantPast
        pendingDBSamples = []
        lastDBFlush = .distantPast
    }

    /// Seed for repetition `index` (0-based) given the current
    /// `seedStrategy` and `fixedSeed`.
    private func seedForRep(_ index: Int) -> Int64? {
        switch seedStrategy {
        case .fixed:
            return fixedSeed
        case .random:
            return Int64.random(in: 1...Int64.max)
        }
    }

    /// Start a benchmark session
    func startBenchmark() {
        guard !isRunning else { return }
        guard let model = selectedModel else {
            error = .modelLoadFailed(modelId: "none", reason: "No model selected")
            return
        }

        resetPerRepState()

        // Group-level state setup — happens once whether we run a
        // single rep or N reps in a group. The per-rep work (session
        // create, inference, completion) lives in runOneRep below.
        isRunning = true
        benchmarkStartTime = Date()
        currentRunGroup = nil
        currentRepetitionIndex = 0

        metricsService.startCollecting()
        if !isCustomProcessActive {
            Task {
                if let port = extractPort(from: connectionURL) {
                    if let detected = await metricsService.autoDetectByPort(port) {
                        Log.benchmark.info("Port \(port) → \(detected.name) (PID \(detected.pid), \(Formatters.bytes(detected.memoryBytes)))")
                    }
                }
            }
        }
        startElapsedTimer()
        startUIUpdateTimer()
        inferenceService.setBackend(selectedBackend)

        benchmarkTask = Task {
            if repetitions > 1 {
                await runGroup(model: model)
            } else {
                do {
                    _ = try await runOneRep(model: model, runGroupId: nil, seed: nil)
                } catch is CancellationError {
                    // runOneRep already marked the session cancelled
                } catch let anubisError as AnubisError {
                    self.error = anubisError
                } catch {
                    if elapsedTime < 1.0 {
                        self.error = .invalidResponse(details: error.localizedDescription)
                    } else {
                        self.error = .streamingError(reason: error.localizedDescription)
                    }
                }
            }
            await finishBenchmark()
        }
    }

    /// Run a single repetition: create session, stream inference,
    /// complete (or mark cancelled/failed), persist. Returns the
    /// finalised session. Throws CancellationError when the surrounding
    /// task is cancelled; throws other errors so the caller can decide
    /// whether to surface them or continue a group loop.
    private func runOneRep(model: ModelInfo, runGroupId: Int64?, seed: Int64?) async throws -> BenchmarkSession {
        var session = BenchmarkSession(
            modelId: model.id,
            modelName: model.name,
            backend: selectedBackend,
            connectionName: connectionName,
            prompt: promptText,
            modelQuantization: model.quantization,
            modelFormat: model.modelFormat?.rawValue
        )
        session.runGroupId = runGroupId
        currentSession = session

        do {
            try await databaseManager.queue.write { db in
                try session.insert(db)
            }
            currentSession = session

            let request = InferenceRequest(
                model: model.id,
                prompt: promptText,
                systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
                maxTokens: maxTokens,
                temperature: temperature,
                topP: topP,
                ollamaThinkMode: ollamaThinkMode,
                seed: seed
            )

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

            self.streamLock.withLock { $0 = StreamBuffers() }

            let stream = await inferenceService.generate(request: request)
            let startTime = Date()
            self.streamLock.withLock { $0.startTime = startTime }
            let instantaneousSampleInterval: TimeInterval = 0.25

            if let sessionId = session.id {
                startSampleCollection(sessionId: sessionId)
            }

            let lock = self.streamLock
            let consumerRepIdx = currentRepetitionIndex
            let consumerSessionId = session.id ?? -1
            // High priority: under heavy chart-rendering load (rendering
            // the run-group banner + N-rep progress + live charts at the
            // start of a group), default-priority tasks were being
            // starved on the cooperative pool. URLSession bytes piled
            // up in its internal buffer un-drained → TCP backpressure →
            // Ollama buffered server-side → user-visible 6s chunk gaps.
            // Boosting to .userInteractive makes the consumer pre-empt
            // other cooperative work so the socket always gets drained.
            self.consumeTask = Task.detached(priority: .userInteractive) { [lock] in
                // Inter-chunk gap histogram — surfaces backend-side
                // buffering issues at very low overhead (just bucket
                // increments per chunk + one log line at rep end).
                var lastChunkArrival: Date? = nil
                var gapBuckets: (under10: Int, under100: Int, under500: Int, under2000: Int, over2000: Int) = (0, 0, 0, 0, 0)
                var maxGap: Double = 0
                var chunkIdx = 0

                for try await chunk in stream {
                    if Task.isCancelled { break }
                    let chunkArrivedAt = Date()

                    if let prev = lastChunkArrival {
                        let gap = chunkArrivedAt.timeIntervalSince(prev)
                        switch gap {
                        case ..<0.010:   gapBuckets.under10 += 1
                        case ..<0.100:   gapBuckets.under100 += 1
                        case ..<0.500:   gapBuckets.under500 += 1
                        case ..<2.000:   gapBuckets.under2000 += 1
                        default:         gapBuckets.over2000 += 1
                        }
                        if gap > maxGap { maxGap = gap }
                    }
                    lastChunkArrival = chunkArrivedAt
                    chunkIdx += 1

                    lock.withLock { buf in
                        buf.text += chunk.text
                        buf.tokenCount += 1
                        buf.chunkCount += 1
                        buf.bytesReceived += chunk.text.utf8.count

                        let now = Date()
                        if buf.lastSampleTime == .distantPast {
                            buf.lastSampleTime = now
                            buf.lastSampleTokens = buf.tokenCount
                        } else {
                            let delta = now.timeIntervalSince(buf.lastSampleTime)
                            if delta >= instantaneousSampleInterval {
                                let rate = Double(buf.tokenCount - buf.lastSampleTokens) / delta
                                buf.peakTps = max(buf.peakTps, rate)
                                buf.lastSampleTime = now
                                buf.lastSampleTokens = buf.tokenCount
                            }
                        }

                        if buf.firstTokenTime == nil && !chunk.text.isEmpty {
                            buf.firstTokenTime = now
                        }
                        if chunk.done, let s = chunk.stats { buf.stats = s }
                    }
                }
                // End-of-rep chunk-gap histogram — one line per rep,
                // operationally useful for diagnosing future streaming
                // regressions.
                Log.benchmark.info("[CHUNK_HIST] session=\(consumerSessionId, privacy: .public) rep=\(consumerRepIdx, privacy: .public) total_chunks=\(chunkIdx, privacy: .public) under10ms=\(gapBuckets.under10, privacy: .public) under100ms=\(gapBuckets.under100, privacy: .public) under500ms=\(gapBuckets.under500, privacy: .public) under2s=\(gapBuckets.under2000, privacy: .public) over2s=\(gapBuckets.over2000, privacy: .public) max_gap=\(maxGap, privacy: .public)s")
            }

            do {
                try await consumeTask!.value
            } catch is CancellationError {
                // handled below via Task.isCancelled
            } catch {
                throw error
            }
            self.consumeTask = nil
            self.inferenceService.clearGenerating()

            let finalBuf = streamLock.withLock { $0 }
            flushTextOnly()
            flushMetricUpdates()

            // Flush per-sample data so it's in the DB before the
            // group orchestrator re-aggregates session-level fields.
            await flushSamplesToDatabase()

            // Prefer the backend's own TTFT (oMLX measures it inside the decode
            // loop); fall back to our first-chunk wall-clock timing otherwise.
            let ttft: TimeInterval? = finalBuf.stats?.serverReportedTTFT
                ?? finalBuf.firstTokenTime.map { $0.timeIntervalSince(startTime) }
            let powerSummary = BenchmarkSample.computePowerSummary(from: self.currentSamplesInternal)
            let backendName = self.metricsService.latestMetrics?.backendProcessName

            if let finalStats = finalBuf.stats {
                session.complete(
                    with: finalStats,
                    response: responseText,
                    timeToFirstToken: ttft,
                    peakMemoryBytes: currentPeakMemory > 0 ? currentPeakMemory : nil,
                    powerSummary: powerSummary,
                    backendProcessName: backendName
                )
            } else {
                let duration = Date().timeIntervalSince(startTime)
                let manualStats = InferenceStats(
                    totalTokens: finalBuf.tokenCount,
                    promptTokens: 0,
                    completionTokens: finalBuf.tokenCount,
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

            try await databaseManager.queue.write { db in
                try session.update(db)
            }

            currentSession = session
            currentSessionLeaderboardSubmitted = false
            self.debugState.phase = .complete
            self.debugState.completedAt = Date()
            if let finalStats = finalBuf.stats {
                self.debugState.finalTokensPerSecond = finalStats.tokensPerSecond
                self.debugState.finalTotalTokens = finalStats.totalTokens
                if finalStats.promptProcessingSpeed > 0 {
                    self.prefillTokensPerSecond = finalStats.promptProcessingSpeed
                }
            }

            // Auto-submit hook — fires after every successful rep when
            // the user has opted in AND saved a display name. Each rep
            // posts independently with its group context, so a 5-rep
            // group becomes 5 group-linked rows (consistent with the
            // existing per-rep submission model). Server rate-limit
            // naturally caps aggressive runs at 10/hr per machine.
            if autoSubmitLeaderboardEnabled,
               let displayName = leaderboardDisplayName,
               !displayName.isEmpty,
               session.status == .completed {
                autoSubmitToLeaderboard(session: session, displayName: displayName)
            }

            return session

        } catch is CancellationError {
            self.inferenceService.clearGenerating()
            session.cancel()
            try? await databaseManager.queue.write { db in
                try session.update(db)
            }
            currentSession = session
            throw CancellationError()

        } catch {
            self.inferenceService.clearGenerating()
            session.fail()
            // Stash the error description in `response` so failed
            // sessions are diagnosable from the History view without
            // a dedicated error-message column. Prefixed so it's
            // unambiguous when reading back.
            session.response = "[ERROR] \(error.localizedDescription)"
            try? await databaseManager.queue.write { db in
                try session.update(db)
            }
            currentSession = session
            self.debugState.phase = .error
            self.debugState.errorMessage = error.localizedDescription
            self.debugState.completedAt = Date()

            #if DEBUG
            print("[Benchmark] inference failed after \(String(format: "%.2f", elapsedTime))s: \(error)")
            #endif
            throw error
        }
    }

    /// Diagnostic snapshot used at rep boundaries. Catches accumulating
    /// state that would explain the "subsequent reps get slower" report.
    private func dumpRepBoundarySnapshot(_ label: String, repIdx: Int?, total: Int?) {
        let chart = chartStore.chartData
        let repTag = repIdx.map { "rep=\($0+1)/\(total ?? 0)" } ?? "—"
        Log.benchmark.info("""
        [N-RUN] \(label, privacy: .public) \(repTag, privacy: .public) \
        samples_in_mem=\(self.currentSamplesInternal.count, privacy: .public) \
        pending_db=\(self.pendingDBSamples.count, privacy: .public) \
        chart_tps_pts=\(chart.tokensPerSecond.count, privacy: .public) \
        chart_sys_pwr_pts=\(chart.systemPower.count, privacy: .public) \
        chart_gpu_util_pts=\(chart.gpuUtilization.count, privacy: .public) \
        elapsed=\(self.elapsedTime, privacy: .public)s
        """)
    }

    /// Orchestrate an N-rep run group. Creates the group, loops calling
    /// runOneRep with per-rep seeds and the group's id, aggregates
    /// stats from completed sessions, finalises the group state.
    private func runGroup(model: ModelInfo) async {
        var group = BenchmarkRunGroup(
            modelId: model.id,
            modelName: model.name,
            backend: selectedBackend,
            prompt: promptText,
            modelQuantization: model.quantization,
            modelFormat: model.modelFormat?.rawValue,
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens,
            seedStrategy: seedStrategy,
            fixedSeed: seedStrategy == .fixed ? fixedSeed : nil,
            repetitions: repetitions
        )

        do {
            try await databaseManager.queue.write { db in
                try group.insert(db)
            }
            currentRunGroup = group
        } catch {
            Log.benchmark.error("Failed to create run group: \(error.localizedDescription)")
            return
        }

        var completedSessions: [BenchmarkSession] = []
        var cancelled = false

        for repIdx in 0..<repetitions {
            if Task.isCancelled { cancelled = true; break }

            currentRepetitionIndex = repIdx + 1

            // Reset per-rep state for repetitions after the first
            // (the first rep was reset in startBenchmark).
            if repIdx > 0 {
                // Give the backend a beat to recover between requests.
                // LM Studio / llama.cpp-style servers reject the
                // immediately-following request when reps are spaced
                // <~150 ms apart (every-other-rep failure pattern
                // observed 2026-05-22 in N>=2 groups). 250 ms is
                // empirically enough and adds at most ~1 s to a 5-rep
                // group.
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { cancelled = true; break }
                dumpRepBoundarySnapshot("BEFORE_RESET", repIdx: repIdx, total: repetitions)
                resetPerRepState()
                dumpRepBoundarySnapshot("AFTER_RESET", repIdx: repIdx, total: repetitions)
            } else {
                dumpRepBoundarySnapshot("REP_START_FIRST", repIdx: repIdx, total: repetitions)
            }

            let seed = seedForRep(repIdx)
            let repStart = Date()
            do {
                let session = try await runOneRep(
                    model: model,
                    runGroupId: group.id,
                    seed: seed
                )
                let repWall = Date().timeIntervalSince(repStart)
                Log.benchmark.info("[N-RUN] REP_DONE rep=\(repIdx + 1, privacy: .public)/\(self.repetitions, privacy: .public) wall=\(repWall, privacy: .public)s session_id=\(session.id ?? -1, privacy: .public) status=\(session.status.rawValue, privacy: .public)")
                if session.status == .completed {
                    completedSessions.append(session)
                    group.completedRepetitions += 1
                    try? await databaseManager.queue.write { db in
                        try group.update(db)
                    }
                    currentRunGroup = group
                }
            } catch is CancellationError {
                cancelled = true
                break
            } catch {
                // Single rep failed — log and continue with the next.
                // Surfacing the error would let the user retry the group,
                // but for now we just record the failed session and
                // keep going so partial results survive.
                Log.benchmark.error("Run group rep \(repIdx + 1)/\(self.repetitions) failed: \(error.localizedDescription)")
            }
        }

        group.recomputeAggregates(from: completedSessions)
        group.completedAt = Date()
        if cancelled {
            group.status = .cancelled
        } else if completedSessions.isEmpty {
            group.status = .failed
        } else {
            group.status = .completed
        }

        try? await databaseManager.queue.write { db in
            try group.update(db)
        }
        currentRunGroup = group
        currentRepetitionIndex = 0

        // Load the full-group chart since groupViewMode defaults to
        // .fullGroup. If the user toggles to .lastRep, the
        // groupViewMode subscription will swap back to per-rep samples.
        await reloadChartForCurrentViewMode()
    }

    /// Stop the current benchmark
    func stopBenchmark() {
        consumeTask?.cancel()
        consumeTask = nil
        benchmarkTask?.cancel()
        benchmarkTask = nil
    }

    /// Load recent benchmark sessions from database
    /// Load recent benchmark sessions for the sidebar / history view.
    ///
    /// Default limit bumped from 20 → 200 after profiling on a typical
    /// machine showed no perceptible load delay even at 200 rows
    /// (issue #26 — users couldn't see or delete sessions past the
    /// first 20). The History view passes its own larger limit when
    /// the user picks "Show: 500 / All".
    func loadRecentSessions(limit: Int = 200) async {
        do {
            recentSessions = try await databaseManager.queue.read { db in
                try BenchmarkSession.fetchRecent(db: db, limit: limit)
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

    // MARK: - Leaderboard auto-submit

    /// Persisted opt-in: when true, every successful rep auto-uploads
    /// to the community leaderboard. Off by default. UI lives in
    /// Settings → Leaderboard.
    var autoSubmitLeaderboardEnabled: Bool {
        UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.autoSubmitLeaderboard)
    }

    /// Currently-saved display name (set via the upload sheet or
    /// Settings). nil if the user has never submitted before.
    var leaderboardDisplayName: String? {
        let v = UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.leaderboardDisplayName) ?? ""
        return v.isEmpty ? nil : v
    }

    /// Fire an auto-submit upload in a detached task. Silent on
    /// failure — surfaces via lastLeaderboardSubmissionError, not a
    /// modal. Pulls the current run group's metadata so the rep
    /// submission carries proper context.
    private func autoSubmitToLeaderboard(session: BenchmarkSession, displayName: String) {
        leaderboardSubmissionInProgress = true
        let group = currentRunGroup
        let repIdx = currentRepetitionIndex > 0
            ? currentRepetitionIndex
            : currentRunGroup?.completedRepetitions
        Task { [weak self] in
            do {
                let service = LeaderboardService()
                _ = try await service.submit(
                    session: session,
                    displayName: displayName,
                    group: group,
                    repetitionIndex: repIdx
                )
                await MainActor.run {
                    self?.currentSessionLeaderboardSubmitted = true
                    self?.lastLeaderboardSubmissionError = nil
                    self?.leaderboardSubmissionInProgress = false
                    Log.benchmark.info("[LEADERBOARD] auto-submitted session id=\(session.id ?? -1, privacy: .public)")
                }
            } catch {
                await MainActor.run {
                    self?.lastLeaderboardSubmissionError = error.localizedDescription
                    self?.leaderboardSubmissionInProgress = false
                    Log.benchmark.warning("[LEADERBOARD] auto-submit failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Called by the upload sheet after a successful manual submission
    /// so the toolbar pill switches to its "submitted" state and the
    /// auto-submit path doesn't re-fire (idempotency).
    func markCurrentSessionLeaderboardSubmitted() {
        currentSessionLeaderboardSubmitted = true
        lastLeaderboardSubmissionError = nil
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

    /// Delete a set of sessions by id in one DB transaction.
    /// Used by the History view's multi-select bulk delete (issue #26).
    /// Reloads the current limit after deletion so the list refreshes.
    func deleteSessions(ids: Set<Int64>, reloadLimit: Int = 200) async {
        guard !ids.isEmpty else { return }
        do {
            try await databaseManager.queue.write { db in
                for id in ids {
                    try BenchmarkSample.deleteForSession(db: db, sessionId: id)
                    try db.execute(sql: "DELETE FROM benchmark_session WHERE id = ?", arguments: [id])
                }
            }
            await loadRecentSessions(limit: reloadLimit)
        } catch {
            Log.benchmark.error("Failed to delete \(ids.count) sessions: \(error.localizedDescription)")
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

    // MARK: - Ollama Pull

    func startPull() {
        showPullSheet = true
        pullModelName = ""
        pullStatus = ""
        pullProgress = 0
    }

    func pullModel() async {
        guard !pullModelName.isEmpty else { return }

        // Cancel any prior pull that was somehow still in flight
        // (e.g. the user re-triggered before the previous one
        // finished/cancelled cleanly).
        pullTask?.cancel()

        isPulling = true
        pullStatus = "Starting..."
        pullProgress = 0

        let modelName = pullModelName

        // Run the stream consume inside a tracked Task so cancelPull
        // can interrupt it. Capture self weakly — if the view model
        // is torn down mid-pull we want the inner task to bail rather
        // than hold a strong cycle through the closure.
        let task = Task { [weak self] in
            guard let self = self else { return }
            do {
                let stream = await self.inferenceService.ollamaClient.pullModel(modelName)
                for try await progress in stream {
                    if Task.isCancelled { break }
                    self.pullStatus = progress.status
                    if let percent = progress.percentComplete {
                        self.pullProgress = percent
                    }
                    if progress.status == "success" { break }
                }
                if Task.isCancelled {
                    self.pullStatus = "Cancelled"
                } else {
                    await self.loadModels()
                    self.showPullSheet = false
                    self.pullModelName = ""
                }
            } catch is CancellationError {
                self.pullStatus = "Cancelled"
            } catch {
                if Task.isCancelled {
                    self.pullStatus = "Cancelled"
                } else {
                    self.pullStatus = "Error: \(error.localizedDescription)"
                }
            }
            self.isPulling = false
            self.pullTask = nil
        }
        pullTask = task
        await task.value
    }

    func cancelPull() {
        // Cancel the in-flight pull first so the HTTP connection
        // closes and the underlying URLSession.bytes read stops
        // (the AsyncThrowingStream's onTermination handler in
        // OllamaClient.pullModel propagates this all the way down).
        // Then reset the user-facing state.
        pullTask?.cancel()
        pullTask = nil
        showPullSheet = false
        pullModelName = ""
        pullStatus = ""
        pullProgress = 0
        isPulling = false
    }

    // MARK: - Browse Library

    /// Open the browse sheet and load the default library view
    /// (top models, no search filter).
    func openBrowseLibrary() {
        showBrowseLibrarySheet = true
        librarySearchQuery = ""
        Task { await reloadLibrary(forceRefresh: false) }
    }

    /// (Re)fetch the library — used by the initial open, the search
    /// input on debounce, and the Refresh button. forceRefresh
    /// bypasses the 24h cache.
    func reloadLibrary(forceRefresh: Bool = false) async {
        libraryLoading = true
        libraryError = nil
        let q = librarySearchQuery
        do {
            let entries = try await OllamaLibraryService.shared.fetch(
                query: q.isEmpty ? nil : q,
                forceRefresh: forceRefresh
            )
            libraryEntries = entries
        } catch {
            libraryError = error.localizedDescription
            libraryEntries = []
        }
        libraryLoading = false
    }

    /// Triggered when the user picks an entry (optionally with a
    /// specific size tag). Sets the pull-name and hands off to the
    /// existing pull flow so progress UI is unified — the browse
    /// sheet dismisses and the pull sheet takes over.
    func pullFromLibrary(_ entry: OllamaLibraryEntry, size: String? = nil) {
        pullModelName = entry.pullSpec(size: size)
        showBrowseLibrarySheet = false
        showPullSheet = true
        Task { await pullModel() }
    }

    // MARK: - oMLX Model Browser / Downloader

    @Published var showOMLXBrowserSheet = false
    @Published private(set) var omlxBrowseModels: [OMLXHFModel] = []
    @Published private(set) var omlxBrowseLoading = false
    @Published private(set) var omlxBrowseError: String?
    @Published var omlxBrowseQuery = ""
    /// Repo currently downloading (nil when idle).
    @Published private(set) var omlxDownloadingRepo: String?
    @Published private(set) var omlxDownloadProgress: Double = 0   // 0–1
    @Published private(set) var omlxDownloadStatus: String = ""
    private var omlxDownloadTask: Task<Void, Never>?
    private var omlxActiveTaskId: String?

    /// The oMLX client for the currently selected OpenAI-compatible backend.
    private var currentOMLXClient: OpenAICompatibleClient? {
        guard isBuiltInOMLXBackend || isVerifiedOMLX,
              let configId = inferenceService.currentOpenAIConfig?.id else { return nil }
        return inferenceService.openAIClient(for: configId)
    }

    var isDownloadingOMLXModel: Bool { omlxDownloadingRepo != nil }

    func openOMLXBrowser() {
        showOMLXBrowserSheet = true
        omlxBrowseQuery = ""
        Task { await reloadOMLXBrowse() }
    }

    /// Load recommended models (empty query) or search results.
    func reloadOMLXBrowse() async {
        guard let client = currentOMLXClient else {
            omlxBrowseError = "oMLX backend is not selected."
            return
        }
        omlxBrowseLoading = true
        omlxBrowseError = nil
        let query = omlxBrowseQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let models = query.isEmpty
                ? try await client.hfRecommended()
                : try await client.hfSearch(query: query)
            // Ignore late results from a superseded query.
            if query == omlxBrowseQuery.trimmingCharacters(in: .whitespacesAndNewlines) {
                omlxBrowseModels = models
            }
        } catch {
            omlxBrowseError = (error as? OMLXAdminError)?.errorDescription ?? error.localizedDescription
            omlxBrowseModels = []
        }
        omlxBrowseLoading = false
    }

    /// True when a browser entry is already present locally.
    func isOMLXModelInstalled(_ repoId: String) -> Bool {
        let sanitized = repoId.replacingOccurrences(of: "/", with: "--")
        return availableModels.contains { $0.id == sanitized || $0.id == repoId }
    }

    /// Download an HF model via oMLX, polling task progress until done.
    func downloadOMLXModel(_ repoId: String) {
        guard let client = currentOMLXClient, omlxDownloadingRepo == nil else { return }
        omlxDownloadingRepo = repoId
        omlxDownloadProgress = 0
        omlxDownloadStatus = "Starting…"
        omlxActiveTaskId = nil
        omlxDownloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.hfDownload(repoId: repoId)
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 800_000_000)
                    let tasks = try await client.hfTasks()
                    guard let t = tasks
                        .filter({ $0.repoId == repoId })
                        .max(by: { $0.createdAt < $1.createdAt }) else { continue }
                    self.omlxActiveTaskId = t.taskId
                    self.omlxDownloadProgress = t.progress / 100.0
                    self.omlxDownloadStatus = Self.omlxStatusLabel(t)
                    if t.status == "completed" { break }
                    if t.status == "failed" {
                        self.error = .backendMessage(t.error.isEmpty ? "Download failed." : t.error)
                        break
                    }
                    if t.status == "cancelled" { break }
                }
                await self.loadModels()  // pick up the newly downloaded model
            } catch is CancellationError {
            } catch let e as OMLXAdminError {
                self.error = .backendMessage(e.errorDescription ?? "Download failed.")
            } catch {
                self.error = .backendMessage("Download failed: \(error.localizedDescription)")
            }
            self.omlxDownloadingRepo = nil
            self.omlxActiveTaskId = nil
            self.omlxDownloadTask = nil
        }
    }

    func cancelOMLXDownload() {
        omlxDownloadTask?.cancel()
        omlxDownloadTask = nil
        if let id = omlxActiveTaskId, let client = currentOMLXClient {
            Task { try? await client.hfCancel(id) }
        }
        omlxDownloadingRepo = nil
        omlxActiveTaskId = nil
    }

    private static func omlxStatusLabel(_ t: OMLXHFTask) -> String {
        switch t.status {
        case "downloading":
            if t.totalSize > 0 {
                return "Downloading \(Formatters.bytes(t.downloadedSize)) / \(Formatters.bytes(t.totalSize))"
            }
            return "Downloading…"
        case "pending": return "Queued…"
        case "completed": return "Completed"
        case "failed": return "Failed"
        case "cancelled": return "Cancelled"
        default: return t.status.capitalized
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

    // MARK: - Window Management

    /// Open the benchmark history in a resizable window
    func openHistoryWindow() {
        // Bring existing window to front if already open
        if let existing = historyWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(self)
            return
        }

        let view = SessionHistoryView(viewModel: self)
        let controller = NSHostingController(rootView: view)
        let mask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: mask,
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.title = "Benchmark History"
        window.minSize = NSSize(width: 600, height: 400)
        window.isReleasedWhenClosed = false
        window.tabbingIdentifier = "com.anubis.history"
        window.tabbingMode = .preferred
        let autosaveName = NSWindow.FrameAutosaveName("AnubisHistoryWindow")
        if !window.setFrameAutosaveName(autosaveName) {
            window.center()
        } else if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            window.setContentSize(NSSize(width: 900, height: 600))
            window.center()
        }
        window.makeKeyAndOrderFront(self)
        historyWindow = window
    }

    /// Open a session detail as a new tab in the history window
    func openSessionDetailTab(session: BenchmarkSession) {
        guard let sessionId = session.id else { return }

        // If already open, bring to front
        if let existing = sessionDetailWindows[sessionId], existing.isVisible {
            existing.makeKeyAndOrderFront(self)
            return
        }

        let view = SessionDetailView(session: session, viewModel: self)
            .frame(minWidth: 500, minHeight: 400)
        let controller = NSHostingController(rootView: view)
        let mask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: mask,
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.title = "\(session.modelName) — \(Formatters.relativeDate(session.startedAt))"
        window.minSize = NSSize(width: 500, height: 400)
        window.isReleasedWhenClosed = false
        window.tabbingIdentifier = "com.anubis.history"
        window.tabbingMode = .preferred

        // Add as a tab to the history window if it exists
        if let historyWin = historyWindow, historyWin.isVisible {
            historyWin.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(self)
        } else {
            window.center()
            window.makeKeyAndOrderFront(self)
        }
        sessionDetailWindows[sessionId] = window
    }

    /// Open the expanded metrics dashboard in a resizable window
    func openExpandedMetricsWindow() {
        if let existing = expandedMetricsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(self)
            return
        }

        // Size the view to fill the screen by default
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = max(900, screenFrame.width)
        let height = max(700, screenFrame.height)

        let view = ExpandedMetricsView(viewModel: self)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        let controller = NSHostingController(rootView: view)

        let mask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: mask,
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.title = "Benchmark Results — \(selectedModel?.name ?? "No Model")"
        window.minSize = NSSize(width: 700, height: 500)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        let autosaveName = NSWindow.FrameAutosaveName("AnubisExpandedMetricsWindow")
        if !window.setFrameAutosaveName(autosaveName) {
            // First launch or name collision — set explicit frame and center
            window.setFrame(NSRect(x: 0, y: 0, width: width, height: height), display: false)
            window.center()
        } else if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            // Restored frame is too small (e.g. was minimized) — reset to default
            window.setFrame(NSRect(x: 0, y: 0, width: width, height: height), display: false)
            window.center()
        }
        window.makeKeyAndOrderFront(self)
        expandedMetricsWindow = window
    }

    /// Open the per-core CPU detail window
    func openCoreDetailWindow() {
        if let existing = coreDetailWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(self)
            return
        }

        let view = CoreDetailView(viewModel: self)
            .frame(minWidth: 500, minHeight: 400)
        let controller = NSHostingController(rootView: view)

        let mask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: mask,
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.title = "CPU Core Detail"
        window.minSize = NSSize(width: 500, height: 400)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        let autosaveName = NSWindow.FrameAutosaveName("AnubisCoreDetailWindow")
        if !window.setFrameAutosaveName(autosaveName) {
            window.center()
        } else if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            window.setContentSize(NSSize(width: 700, height: 500))
            window.center()
        }
        window.makeKeyAndOrderFront(self)
        coreDetailWindow = window
    }

    /// Open the GPU core detail window
    func openGPUDetailWindow() {
        if let existing = gpuDetailWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(self)
            return
        }

        let view = GPUDetailView(viewModel: self)
            .frame(minWidth: 600, minHeight: 500)
        let controller = NSHostingController(rootView: view)

        let mask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
            styleMask: mask,
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.title = "GPU Core Detail"
        window.minSize = NSSize(width: 600, height: 500)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        let autosaveName = NSWindow.FrameAutosaveName("AnubisGPUDetailWindow")
        if !window.setFrameAutosaveName(autosaveName) {
            window.center()
        } else if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            window.setContentSize(NSSize(width: 800, height: 700))
            window.center()
        }
        window.makeKeyAndOrderFront(self)
        gpuDetailWindow = window
    }

    /// Close any open auxiliary windows (called when navigating away)
    func closeAuxiliaryWindows() {
        historyWindow?.close()
        historyWindow = nil
        expandedMetricsWindow?.close()
        expandedMetricsWindow = nil
        coreDetailWindow?.close()
        coreDetailWindow = nil
        gpuDetailWindow?.close()
        gpuDetailWindow = nil
        for (_, window) in sessionDetailWindows {
            window.close()
        }
        sessionDetailWindows.removeAll()
    }

    // MARK: - Private Methods

    private func setupMetricsSubscription() {
        metricsSubscription = metricsService.$currentMetrics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] metrics in
                guard let self = self else { return }
                // Mutate the underlying state without firing a cascade
                // per field — coalesce into a single notification via
                // notifyMetricsBatchChanged() below. In group streaming
                // that notification is throttled to ~1Hz so MainActor
                // stays available for text flush.
                self.currentMetrics = metrics
                if let perCore = metrics?.perCoreUtilization, !perCore.isEmpty {
                    self.latestPerCoreSnapshot = perCore
                    if self.isRunning {
                        self.perCoreData.append(snapshot: perCore, at: Date())
                    }
                }
                if let metrics = metrics {
                    self.latestGPUUtilization = metrics.gpuUtilization
                    if self.isRunning {
                        self.gpuDetailData.append(metrics: metrics, at: Date())
                    }
                }
                self.notifyMetricsBatchChanged()
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
                self?.flushTextOnly()
            }
        }
    }

    /// Flush ONLY text from stream buffer to ResponseTextStore (called at 10Hz).
    /// Zero BenchmarkViewModel @Published mutations — only touches the isolated
    /// ResponseTextStore, so SwiftUI diffs are limited to StreamingTextView.
    private func flushTextOnly() {
        os_signpost(.begin, log: Signposts.streaming, name: "flushText")
        defer { os_signpost(.end, log: Signposts.streaming, name: "flushText") }

        let text = streamLock.withLock { buf -> String in
            let t = buf.text
            buf.text = ""
            return t
        }

        if streamResponse && !text.isEmpty {
            responseTextStore.append(text)
            responseText += text
        }

        // First token detection (one-time)
        if self.timeToFirstToken == nil {
            let ft = streamLock.withLock { $0.firstTokenTime }
            if let ft {
                self.timeToFirstToken = ft.timeIntervalSince(benchmarkStartTime!)
                self.debugState.firstChunkAt = ft
                Task { await self.fetchModelMemory() }
            }
        }
    }

    /// Flush numeric properties at sample cadence (2Hz from collectSample).
    /// These were @Published — now batched into ONE objectWillChange.send()
    /// per call (see notifyLiveStatsChanged) to collapse Core Animation
    /// transaction storms during streaming.
    private func flushMetricUpdates() {
        os_signpost(.begin, log: Signposts.streaming, name: "flushMetrics")
        defer { os_signpost(.end, log: Signposts.streaming, name: "flushMetrics") }

        let snap = streamLock.withLock { $0 }

        var dirty = false
        if snap.tokenCount != tokensGenerated {
            tokensGenerated = snap.tokenCount
            dirty = true
        }
        if let ftt = snap.firstTokenTime, snap.tokenCount > 0 {
            let genElapsed = Date().timeIntervalSince(ftt)
            let freshTps = genElapsed > 0 ? Double(snap.tokenCount) / genElapsed : 0
            if freshTps != currentTokensPerSecond {
                currentTokensPerSecond = freshTps
                dirty = true
            }
        }
        if snap.peakTps != peakTokensPerSecond {
            peakTokensPerSecond = snap.peakTps
            dirty = true
        }
        if dirty {
            notifyLiveStatsChanged()
        }
    }

    /// Single objectWillChange.send() for a batch of live-stat mutations.
    /// Replaces 8 separate @Published cascades per sample tick. Views
    /// bound to the VM still re-evaluate when this fires, but now ONCE
    /// per batch instead of once per field — collapsing the Core
    /// Animation transactions that were dominating main-thread time.
    private func notifyLiveStatsChanged() {
        objectWillChange.send()
    }

    /// Throttle anchor for the metrics-batch notification. Reset in
    /// resetPerRepState so the first sample of each rep doesn't get
    /// throttled.
    private var lastMetricsNotificationAt: Date = .distantPast

    /// Coalesces currentMetrics / latestPerCoreSnapshot / perCoreData /
    /// debugState mutations into a single objectWillChange.send().
    /// In group streaming (currentRunGroup running, repetitions > 1)
    /// throttles to ~1Hz to free MainActor for text flush — otherwise
    /// at full sample cadence (2Hz). Single-run mode always fires at
    /// 2Hz since main isn't competing with the group banner / dots.
    private func notifyMetricsBatchChanged() {
        let isGroupStreaming = currentRunGroup?.status == .running && repetitions > 1
        let throttle: TimeInterval = isGroupStreaming ? 1.0 : 0.5
        let now = Date()
        if now.timeIntervalSince(lastMetricsNotificationAt) < throttle {
            return
        }
        lastMetricsNotificationAt = now
        objectWillChange.send()
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
        os_signpost(.begin, log: Signposts.streaming, name: "collectSample")
        defer { os_signpost(.end, log: Signposts.streaming, name: "collectSample") }

        guard isRunning else { return }

        // [GUARD 1] Generation check: Timer.invalidate() doesn't cancel
        // Tasks already enqueued from a recent fire. A leftover Task
        // from the previous rep's timer can run after the rep
        // transition and write a sample to the OLD session id with
        // freshly-reset (tokens=0) state. Drop it here so it can't
        // pollute the chart.
        guard sessionId == currentSession?.id else {
            return
        }

        // [GUARD 2] Throttle floor: if the MainActor was briefly busy,
        // multiple Timer fires can queue Tasks that then run back-to-
        // back with sub-millisecond gaps. Each such Task would write a
        // sample with the same token count but a tiny dt — feeding the
        // chart's instantTps calculation a "delta / 0.0002s" spike.
        // Drop the rapid-fire duplicates and let the next real fire
        // (≥ minimumSampleSpacing later) produce the canonical sample.
        let now = Date()
        let sinceLast = now.timeIntervalSince(lastSampleCollectedAt)
        if sinceLast < minimumSampleSpacing {
            return
        }
        lastSampleCollectedAt = now

        // Flush numeric @Published properties at sample cadence (2Hz)
        flushMetricUpdates()

        // Read cached metrics — NO system calls, just a property read
        guard let metrics = metricsService.latestMetrics else { return }

        // Process tree walk may miss the model runner process (e.g. ollama_llama_server).
        // When the API reports a model allocation larger than the tree RSS, the runner
        // wasn't captured — add model size on top. When tree RSS already exceeds the
        // model allocation, the tree captured everything — use it as-is.
        let reportedMemory = metrics.memoryUsedBytes
        let effectiveMemory: Int64
        if modelMemoryTotal > 0, reportedMemory < modelMemoryTotal {
            effectiveMemory = reportedMemory + modelMemoryTotal
        } else {
            effectiveMemory = reportedMemory
        }

        let snapshotMetrics = SystemMetrics(
            timestamp: Date(),
            gpuUtilization: metrics.gpuUtilization,
            cpuUtilization: metrics.cpuUtilization,
            memoryUsedBytes: effectiveMemory,
            memoryTotalBytes: metrics.memoryTotalBytes,
            thermalState: metrics.thermalState,
            gpuPowerWatts: metrics.gpuPowerWatts,
            cpuPowerWatts: metrics.cpuPowerWatts,
            anePowerWatts: metrics.anePowerWatts,
            dramPowerWatts: metrics.dramPowerWatts,
            systemPowerWatts: metrics.systemPowerWatts,
            gpuFrequencyMHz: metrics.gpuFrequencyMHz,
            backendProcessMemoryBytes: effectiveMemory > 0 ? effectiveMemory : nil,
            backendProcessCPUPercent: metrics.backendProcessCPUPercent,
            backendProcessName: metrics.backendProcessName
        )

        let (snapTokens, snapFirstTokenTime) = streamLock.withLock { ($0.tokenCount, $0.firstTokenTime) }
        let snapTps: Double
        if let ftt = snapFirstTokenTime, snapTokens > 0 {
            let genElapsed = Date().timeIntervalSince(ftt)
            snapTps = genElapsed > 0 ? Double(snapTokens) / genElapsed : 0
        } else {
            snapTps = 0
        }

        var sample = BenchmarkSample(
            sessionId: sessionId,
            metrics: snapshotMetrics,
            tokensGenerated: snapTokens,
            cumulativeTokensPerSecond: snapTps
        )

        // Assign a local ID for in-memory tracking (DB will assign real ID on flush)
        currentSamplesInternal.append(sample)
        pendingDBSamples.append(sample)

        // Batch all live-stat mutations and emit ONE objectWillChange.send()
        // at the end via notifyLiveStatsChanged(). Pre-refactor this block
        // was 5 separate @Published mutations per sample tick, which
        // multiplied into the CA::Transaction commit storm visible in the
        // 2026-05-22 lag sample.
        var statsDirty = false

        // Track peak backend process memory (using compensated value)
        if effectiveMemory > currentPeakMemory {
            currentPeakMemory = effectiveMemory
            statsDirty = true
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

        if powerSampleCount > 0 {
            let newAvgGpu = gpuPowerSum / Double(powerSampleCount)
            if newAvgGpu != avgGpuPower { avgGpuPower = newAvgGpu; statsDirty = true }
            if pendingPeakGpuPower != peakGpuPower { peakGpuPower = pendingPeakGpuPower; statsDirty = true }

            let newAvgSys = systemPowerSum / Double(powerSampleCount)
            if newAvgSys != avgSystemPower { avgSystemPower = newAvgSys; statsDirty = true }
            if pendingPeakSystemPower != peakSystemPower { peakSystemPower = pendingPeakSystemPower; statsDirty = true }
        }

        if statsDirty {
            notifyLiveStatsChanged()
        }

        // Debug state at sample rate (2Hz) — not per-chunk
        let snapDebug = streamLock.withLock { (chunkCount: $0.chunkCount, bytesReceived: $0.bytesReceived) }
        if snapDebug.chunkCount > 0 {
            debugState.chunksReceived = snapDebug.chunkCount
            debugState.bytesReceived = snapDebug.bytesReceived
            debugState.lastChunkAt = Date()
            debugState.phase = .streaming
        }

        // Flush to database periodically (every 5s) instead of on every sample
        if now.timeIntervalSince(lastDBFlush) >= dbFlushInterval {
            await flushSamplesToDatabase()
        }

        // Update chart data at throttled rate (skip entirely when charts are hidden)
        if showLiveCharts, now.timeIntervalSince(lastChartUpdate) >= chartUpdateInterval {
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
        if !streamResponse {
            let remaining = streamLock.withLock { buf -> String in
                let t = buf.text; buf.text = ""; return t
            }
            if !remaining.isEmpty {
                responseText += remaining
            }
            responseTextStore.set(responseText)
        }

        // Final flush of any remaining buffered content
        flushTextOnly()
        flushMetricUpdates()

        // Final power stats flush — one notification covers all four.
        if powerSampleCount > 0 {
            avgGpuPower = gpuPowerSum / Double(powerSampleCount)
            peakGpuPower = pendingPeakGpuPower
            avgSystemPower = systemPowerSum / Double(powerSampleCount)
            peakSystemPower = pendingPeakSystemPower
            notifyLiveStatsChanged()
        }

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

    /// Re-source the chart data based on the current group view mode.
    /// In `.fullGroup` mode after a group has completed, fetches every
    /// sample across every session in the group and concatenates them
    /// into one time-series. In `.lastRep` mode (or when there's no
    /// finished group), keeps the chart pointed at the current
    /// session's samples (already loaded). Safe to call on the main
    /// actor — DB work runs on the GRDB queue, chart update marshals
    /// back to main.
    private func reloadChartForCurrentViewMode() async {
        guard shouldShowGroupMean,
              let groupId = currentRunGroup?.id
        else {
            // Switching back to last-rep: restore the last session's
            // chart from in-memory samples (still populated from the
            // most recent rep).
            let samples = currentSamplesInternal
            let chartData = BenchmarkSample.chartData(from: samples)
            chartStore.update(chartData)
            return
        }

        do {
            let samples = try await databaseManager.queue.read { db -> [BenchmarkSample] in
                try BenchmarkSample
                    .filter(sql: "session_id IN (SELECT id FROM benchmark_session WHERE run_group_id = ?)", arguments: [groupId])
                    .order(Column("timestamp").asc)
                    .fetchAll(db)
            }
            let chartData = BenchmarkSample.chartData(from: samples)
            chartStore.update(chartData)
        } catch {
            Log.benchmark.error("Failed to load group chart data: \(error.localizedDescription)")
        }
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

    /// True when there's a finished group to summarize and the user has
    /// asked for the full-group view rather than the last rep's numbers.
    /// Used by display formatters to decide between group-mean and
    /// session-level values.
    var shouldShowGroupMean: Bool {
        guard groupViewMode == .fullGroup,
              let group = currentRunGroup,
              group.status != .running,
              (group.sampleCount ?? 0) > 1
        else { return false }
        return true
    }

    /// Average tokens per second — uses backend-reported value when complete, live value during run.
    /// In group-mean view after a multi-rep group, returns the group mean instead.
    var effectiveAverageTps: Double {
        if shouldShowGroupMean, let mean = currentRunGroup?.meanTokensPerSecond {
            return mean
        }
        if let session = currentSession, session.status == .completed, let tps = session.tokensPerSecond {
            return tps
        }
        return currentTokensPerSecond
    }

    /// Formatted tokens per second (average)
    var formattedTokensPerSecond: String {
        Formatters.tokensPerSecond(effectiveAverageTps)
    }

    /// Formatted peak tokens per second
    var formattedPeakTokensPerSecond: String {
        Formatters.tokensPerSecond(peakTokensPerSecond)
    }

    /// Formatted process tree memory (includes model + server + children)
    var formattedMemoryUsage: String? {
        let mem = effectiveBackendMemoryBytes
        guard mem > 0 else { return nil }
        return Formatters.bytes(mem)
    }

    /// Formatted total process memory (process tree RSS — includes model in memory)
    var formattedTotalMemory: String {
        let mem = effectiveBackendMemoryBytes
        if mem > 0 {
            return Formatters.bytes(mem)
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

    /// Average GPU power formatted (running avg during benchmark, final after).
    /// In group-mean view, returns the group's mean across all reps.
    var avgGPUPowerFormatted: String {
        if shouldShowGroupMean, let mean = currentRunGroup?.meanGpuPowerWatts {
            return Formatters.watts(mean)
        }
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

    /// Average system power formatted (running avg during benchmark, final after).
    /// In group-mean view, returns the group's mean across all reps.
    var avgSystemPowerFormatted: String {
        if shouldShowGroupMean, let mean = currentRunGroup?.meanSystemPowerWatts {
            return Formatters.watts(mean)
        }
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

    /// TTFT formatted in ms. Group-mean view returns the group's mean
    /// TTFT (the (56 ms – 784 ms) range a 3-rep group exposes lives in
    /// the summary card's CI; this is the headline number).
    var formattedTTFT: String {
        if shouldShowGroupMean, let mean = currentRunGroup?.meanTimeToFirstToken {
            return Formatters.milliseconds(mean * 1000)
        }
        guard let ttft = timeToFirstToken else { return "—" }
        return Formatters.milliseconds(ttft * 1000)
    }

    /// Peak memory formatted. Group-mean view returns the mean of
    /// per-rep peaks; in practice memory is essentially constant
    /// across reps (the model stays resident) so the group mean
    /// equals the per-rep peak.
    var formattedPeakMemory: String {
        if shouldShowGroupMean, let mean = currentRunGroup?.meanPeakMemoryBytes {
            return Formatters.bytes(Int64(mean))
        }
        if currentPeakMemory > 0 {
            return Formatters.bytes(currentPeakMemory)
        }
        if let bytes = currentSession?.peakMemoryBytes {
            return Formatters.bytes(bytes)
        }
        return "—"
    }

    /// Current GPU frequency formatted (live metrics, falling back to session average)
    var currentGPUFrequencyFormatted: String {
        if let freq = currentMetrics?.gpuFrequencyMHz, freq > 0 {
            return String(format: "%.0f MHz", freq)
        }
        if let freq = currentSession?.avgGpuFrequencyMHz, freq > 0 {
            return String(format: "%.0f MHz", freq)
        }
        return "—"
    }

    /// Energy per token formatted as J/tok (avg system power / avg tok/s).
    /// In group-mean view, returns the group's mean J/Tok across all reps.
    var currentWattsPerTokenFormatted: String {
        if shouldShowGroupMean, let mean = currentRunGroup?.meanWattsPerToken {
            return String(format: "%.2f J/tok", mean)
        }
        if let session = currentSession, session.status == .completed,
           let wpt = session.avgWattsPerToken {
            return String(format: "%.2f J/tok", wpt)
        }
        guard avgSystemPower > 0, currentTokensPerSecond > 0 else { return "—" }
        let wpt = avgSystemPower / currentTokensPerSecond
        return String(format: "%.2f J/tok", wpt)
    }

    /// Effective backend memory: compensates when process tree walk misses the model runner.
    /// When the API-reported model allocation exceeds the tree RSS, the runner wasn't captured
    /// — add model size on top. Otherwise the tree already includes it.
    var effectiveBackendMemoryBytes: Int64 {
        let reported = currentMetrics?.memoryUsedBytes ?? 0
        if modelMemoryTotal > 0, reported < modelMemoryTotal {
            return reported + modelMemoryTotal
        }
        return reported
    }

    /// Formatted process memory (process tree RSS — includes model + server + children)
    var formattedBackendMemory: String {
        let mem = effectiveBackendMemoryBytes
        if mem > 0 {
            return Formatters.bytes(mem)
        }
        return "—"
    }

    /// Backend process name (from ProcessMonitor)
    var currentBackendProcessName: String? {
        currentMetrics?.backendProcessName
    }
}
