//
//  FlowExecutor.swift
//  anubis
//
//  Walks a Flow's step tree depth-first, mutating an
//  ExecutionContext (backend / model / prompt / params) as it goes,
//  and executing leaf steps via InferenceService. Every
//  runBenchmark step produces a real BenchmarkSession tagged with
//  the parent FlowRun (and optionally a wrapping BenchmarkRunGroup
//  when nested inside a `repeatN`), so the regular Run History and
//  Reports infrastructure works unchanged.
//
//  v1 deliberately skips MetricsService: there is no live hardware
//  telemetry written for flow-run sessions, just the inference
//  stats reported by the backend. That keeps the executor focused
//  on orchestration and means a long flow can't flood the database
//  with sample rows. Phase 5/6 can wire metrics back in once we
//  have a stable executor surface.
//

import Foundation
import Combine
@preconcurrency import GRDB

@MainActor
final class FlowExecutor: ObservableObject {
    // MARK: - Public State

    enum State: Equatable {
        case idle
        case running
        case completed
        case failed(String)
        case cancelled
    }

    enum StepStatus: Equatable {
        case pending
        case running
        case completed
        case failed(String)
        case skipped(String)
    }

    /// Snapshot of one step's execution state. Keyed by FlowStep.id
    /// in `progress` below; container steps mark themselves running
    /// for their whole sub-tree and completed once children finish.
    struct StepProgress: Identifiable, Equatable {
        let id: UUID
        var status: StepStatus
        var startedAt: Date?
        var endedAt: Date?
        /// Per-step subtitle ("rep 3/5", "model llama3.2:3b", etc).
        var detail: String?
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var progress: [UUID: StepProgress] = [:]
    /// Append-only log of human-readable events. Capped at 500 entries
    /// to keep memory bounded on long flows.
    @Published private(set) var log: [LogEntry] = []
    /// The most recently completed session — handy for the UI to
    /// surface the latest result while the flow keeps running.
    @Published private(set) var latestSession: BenchmarkSession?
    /// The persisted FlowRun row (nil before start).
    @Published private(set) var flowRun: FlowRun?
    /// Aggregate counters for the run summary card.
    @Published private(set) var completedSessionCount: Int = 0
    @Published private(set) var failedSessionCount: Int = 0

    /// Total Run Benchmark invocations expected for the active flow,
    /// snapshotted at start time. Together with attemptedRunCount this
    /// drives the "Run X of Y" header in FlowRunView.
    @Published private(set) var totalExpectedRuns: Int = 0

    /// Number of runBenchmark steps started so far (counts before the
    /// stream begins, so the header advances immediately at each rep
    /// boundary). Includes runs that subsequently fail or cancel —
    /// matches what the user sees in the step tree.
    @Published private(set) var attemptedRunCount: Int = 0

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let message: String

        enum Level { case info, success, warning, error }
    }

    // MARK: - Dependencies

    private let inferenceService: InferenceService
    private let databaseManager: DatabaseManager
    private var rootTask: Task<Void, Never>?

    init(inferenceService: InferenceService, databaseManager: DatabaseManager) {
        self.inferenceService = inferenceService
        self.databaseManager = databaseManager
    }

    // MARK: - Public API

    /// Begin executing `flow`. No-op if already running. The returned
    /// `Task` handle isn't strictly needed (the executor's own
    /// `rootTask` retains it) but it lets callers await completion if
    /// they want to.
    func start(flow: Flow) {
        guard state != .running else { return }
        guard !flow.steps.isEmpty else {
            state = .failed("Flow has no steps")
            return
        }

        // Reset all transient state for a fresh run.
        state = .running
        progress.removeAll()
        log.removeAll()
        latestSession = nil
        flowRun = nil
        completedSessionCount = 0
        failedSessionCount = 0
        attemptedRunCount = 0
        totalExpectedRuns = flow.steps.expectedRunCount

        initializeProgress(steps: flow.steps)

        rootTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runFlow(flow)
        }
    }

    /// Cancel the current flow. Idempotent.
    func stop() {
        rootTask?.cancel()
    }

    // MARK: - Execution Context

    /// Mutable per-flow state. Backends/models/prompts/params set by
    /// state-setting steps stay in effect for every subsequent
    /// runBenchmark until overwritten or popped by a forEach loop.
    private struct ExecutionContext {
        var backend: FlowBackendRef?
        var model: String?
        var prompt: String?
        var params: FlowParameters = .default
    }

    // MARK: - Top-level Run

    private func runFlow(_ flow: Flow) async {
        // Persist the FlowRun row up front so even an early failure
        // leaves a row in history.
        var run = FlowRun(flow: flow)
        do {
            try await databaseManager.queue.write { db in
                try run.insert(db)
            }
        } catch {
            await record(.error, "Failed to create FlowRun: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            return
        }
        self.flowRun = run
        await record(.info, "Flow started: \(flow.name)")

        var context = ExecutionContext()
        var outcome: State = .completed
        var failureMessage: String?

        do {
            try await execute(steps: flow.steps, context: &context, runGroupId: nil)
        } catch is CancellationError {
            outcome = .cancelled
            await record(.warning, "Flow cancelled")
        } catch let error as AnubisError {
            outcome = .failed(error.localizedDescription)
            failureMessage = error.localizedDescription
            await record(.error, "Flow failed: \(error.localizedDescription)")
        } catch {
            outcome = .failed(error.localizedDescription)
            failureMessage = error.localizedDescription
            await record(.error, "Flow failed: \(error.localizedDescription)")
        }

        // Finalize the FlowRun.
        run.endedAt = Date()
        switch outcome {
        case .completed: run.status = .completed
        case .cancelled: run.status = .cancelled
        case .failed: run.status = .failed
        default: run.status = .completed
        }
        run.failureMessage = failureMessage
        try? await databaseManager.queue.write { db in
            try run.update(db)
        }
        self.flowRun = run
        state = outcome

        if outcome == .completed {
            await record(.success, "Flow completed: \(completedSessionCount) session\(completedSessionCount == 1 ? "" : "s")")
        }
    }

    // MARK: - Step Walker

    private func execute(steps: [FlowStep], context: inout ExecutionContext, runGroupId: Int64?) async throws {
        for step in steps {
            try Task.checkCancellation()
            try await executeStep(step, context: &context, runGroupId: runGroupId)
        }
    }

    private func executeStep(
        _ step: FlowStep,
        context: inout ExecutionContext,
        runGroupId: Int64?
    ) async throws {
        markRunning(step.id)
        do {
            switch step.kind {
            case .setBackend(let ref):
                try applySetBackend(ref, context: &context)

            case .setModel(let name):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                context.model = trimmed
                await record(.info, "Model: \(trimmed.isEmpty ? "(empty)" : trimmed)")

            case .setPrompt(let source):
                applySetPrompt(source, context: &context)

            case .setParameters(let params):
                context.params = params
                let thinkNote = params.thinkMode == .auto ? "" : ", thinking=\(params.thinkMode.displayLabel.lowercased())"
                await record(.info, "Parameters: temp=\(fmt(params.temperature)), top-p=\(fmt(params.topP)), max=\(params.maxTokens)\(thinkNote)")

            case .runBenchmark:
                try await runOneBenchmark(context: context, runGroupId: runGroupId)

            case .repeatN(let count, let body):
                try await runRepeat(count: count, body: body, context: &context, parentStepId: step.id)

            case .forEachModel(let models, let body):
                try await runForEach(values: models, body: body, context: &context, parentStepId: step.id) { ctx, value in
                    ctx.model = value
                }

            case .forEachPrompt(let prompts, let body):
                try await runForEach(values: prompts, body: body, context: &context, parentStepId: step.id) { ctx, value in
                    ctx.prompt = value
                }

            case .unloadModel:
                try await runUnload(context: context)

            case .resetConnection:
                inferenceService.reloadConfigurations()
                await record(.info, "Connection reset")

            case .coolDown(let mode):
                try await runCoolDown(mode: mode)

            case .annotate(let text):
                await record(.info, "📝 \(text)")
            }
            markCompleted(step.id)
        } catch is CancellationError {
            markFailed(step.id, "cancelled")
            throw CancellationError()
        } catch {
            markFailed(step.id, error.localizedDescription)
            throw error
        }
    }

    // MARK: - State setters

    private func applySetBackend(_ ref: FlowBackendRef, context: inout ExecutionContext) throws {
        context.backend = ref
        switch ref.type {
        case .ollama, .appleIntelligence:
            inferenceService.setBackend(ref.type)
        case .openai:
            guard let configId = ref.openAIConfigId,
                  let config = inferenceService.configManager.openAIConfigs.first(where: { $0.id == configId }) else {
                throw AnubisError.invalidResponse(details: "Set Backend step targets an OpenAI server that no longer exists")
            }
            inferenceService.setOpenAIBackend(config)
        }
        Task { await record(.info, "Backend: \(ref.type.displayName)") }
    }

    private func applySetPrompt(_ source: FlowPromptSource, context: inout ExecutionContext) {
        switch source {
        case .inline(let text):
            context.prompt = text
            Task { await record(.info, "Prompt set (\(text.count) chars)") }
        case .library(let id):
            // Library lookup lives in a future phase. For now, treat
            // the id as opaque and warn the executor isn't filling it.
            Task { await record(.warning, "Prompt library lookup not implemented (id=\(id)); leaving prompt unset") }
        case .file(_, let name):
            Task { await record(.warning, "File prompt sources not implemented (\(name)); leaving prompt unset") }
        }
    }

    // MARK: - Run Benchmark

    private func runOneBenchmark(context: ExecutionContext, runGroupId: Int64?) async throws {
        guard let backend = context.backend else {
            throw AnubisError.invalidResponse(details: "Run Benchmark with no prior Set Backend step")
        }
        guard let model = context.model, !model.isEmpty else {
            throw AnubisError.invalidResponse(details: "Run Benchmark with no model set")
        }
        guard let prompt = context.prompt, !prompt.isEmpty else {
            throw AnubisError.invalidResponse(details: "Run Benchmark with no prompt set")
        }

        // Compute a per-rep seed when the params demand a fixed one.
        let seed: Int64? = {
            switch context.params.seedStrategy {
            case .fixed: return context.params.fixedSeed
            case .random: return nil
            }
        }()

        // Build the session row up-front so it appears in History
        // immediately (status=.running), and gets the flow tag.
        let connectionName: String? = backend.type == .openai
            ? inferenceService.currentOpenAIConfig?.name
            : nil

        var session = BenchmarkSession(
            modelId: model,
            modelName: model,
            backend: backend.type,
            connectionName: connectionName,
            prompt: prompt
        )
        session.runGroupId = runGroupId
        session.flowRunId = flowRun?.id

        try await databaseManager.queue.write { db in
            try session.insert(db)
        }

        attemptedRunCount += 1
        await record(.info, "Run start (\(attemptedRunCount)/\(totalExpectedRuns)): \(model)")

        let request = InferenceRequest(
            model: model,
            prompt: prompt,
            maxTokens: context.params.maxTokens,
            temperature: context.params.temperature,
            topP: context.params.topP,
            ollamaThinkMode: context.params.thinkMode,
            seed: seed
        )

        let startTime = Date()
        let stream = await inferenceService.generate(request: request)

        var collectedText = ""
        var firstTokenAt: Date?
        var finalStats: InferenceStats?
        var tokenCount = 0

        do {
            for try await chunk in stream {
                try Task.checkCancellation()
                if firstTokenAt == nil && !chunk.text.isEmpty {
                    firstTokenAt = Date()
                }
                collectedText += chunk.text
                tokenCount += 1
                if chunk.done, let stats = chunk.stats {
                    finalStats = stats
                }
            }
        } catch is CancellationError {
            session.cancel()
            try? await databaseManager.queue.write { db in
                try session.update(db)
            }
            inferenceService.clearGenerating()
            throw CancellationError()
        } catch {
            session.fail()
            session.response = "[ERROR] \(error.localizedDescription)"
            try? await databaseManager.queue.write { db in
                try session.update(db)
            }
            inferenceService.clearGenerating()
            failedSessionCount += 1
            await record(.error, "Run failed: \(error.localizedDescription)")
            throw error
        }
        inferenceService.clearGenerating()

        let ttft = firstTokenAt.map { $0.timeIntervalSince(startTime) }
        let stats: InferenceStats
        if let backendStats = finalStats {
            stats = backendStats
        } else {
            let duration = Date().timeIntervalSince(startTime)
            stats = InferenceStats(
                totalTokens: tokenCount,
                promptTokens: 0,
                completionTokens: tokenCount,
                totalDuration: duration,
                promptEvalDuration: 0,
                evalDuration: duration,
                loadDuration: 0,
                contextLength: 0
            )
        }

        session.complete(
            with: stats,
            response: collectedText,
            timeToFirstToken: ttft
        )
        try await databaseManager.queue.write { db in
            try session.update(db)
        }
        latestSession = session
        completedSessionCount += 1

        let tpsText = String(format: "%.1f", session.tokensPerSecond ?? 0)
        let ttftText = ttft.map { String(format: "%.0fms", $0 * 1000) } ?? "—"
        await record(.success, "Run done: \(tpsText) tok/s · TTFT \(ttftText)")
    }

    // MARK: - Repeat container

    private func runRepeat(
        count: Int,
        body: [FlowStep],
        context: inout ExecutionContext,
        parentStepId: UUID
    ) async throws {
        guard !body.isEmpty else {
            await record(.warning, "Repeat block has no children — skipping")
            return
        }
        let safeCount = max(1, count)

        // Wrap repetitions in a BenchmarkRunGroup so the existing
        // group-aggregate UI (mean ± 95% CI) lights up for them too.
        // We need to know the model + params *at the start* of the
        // first iteration to populate the group's config snapshot; if
        // the body doesn't set its own backend/model/prompt, the
        // outer context already has those values.
        let groupSnapshot = makeGroupSnapshot(from: context, repetitions: safeCount)

        var group: BenchmarkRunGroup?
        var groupId: Int64?
        if let snap = groupSnapshot {
            var g = snap
            g.flowRunId = flowRun?.id
            do {
                try await databaseManager.queue.write { db in
                    try g.insert(db)
                }
                group = g
                groupId = g.id
            } catch {
                await record(.warning, "Failed to create run group (\(error.localizedDescription)); proceeding without group aggregates")
            }
        }

        for rep in 1...safeCount {
            try Task.checkCancellation()
            setDetail(parentStepId, "Rep \(rep) of \(safeCount)")
            await record(.info, "Repeat \(rep)/\(safeCount)")
            try await execute(steps: body, context: &context, runGroupId: groupId)
        }

        // Finalize the group: recompute aggregates from its sessions.
        if let id = groupId, var g = group {
            do {
                try await databaseManager.queue.write { db in
                    let sessions = try BenchmarkSession
                        .filter(Column("run_group_id") == id)
                        .fetchAll(db)
                    g.recomputeAggregates(from: sessions)
                    g.completedRepetitions = sessions.filter { $0.status == .completed }.count
                    g.completedAt = Date()
                    g.status = .completed
                    try g.update(db)
                }
            } catch {
                await record(.warning, "Failed to finalize run group: \(error.localizedDescription)")
            }
        }
    }

    /// Build a group snapshot from current context. Returns nil if
    /// the required pieces (model + prompt + backend) aren't set yet
    /// — in which case repeat still runs, just without aggregates.
    private func makeGroupSnapshot(from context: ExecutionContext, repetitions: Int) -> BenchmarkRunGroup? {
        guard let backend = context.backend,
              let model = context.model, !model.isEmpty,
              let prompt = context.prompt else { return nil }
        return BenchmarkRunGroup(
            modelId: model,
            modelName: model,
            backend: backend.type,
            prompt: prompt,
            temperature: context.params.temperature,
            topP: context.params.topP,
            maxTokens: context.params.maxTokens,
            seedStrategy: context.params.seedStrategy,
            fixedSeed: context.params.fixedSeed,
            repetitions: repetitions
        )
    }

    // MARK: - ForEach containers

    private func runForEach(
        values: [String],
        body: [FlowStep],
        context: inout ExecutionContext,
        parentStepId: UUID,
        apply: (inout ExecutionContext, String) -> Void
    ) async throws {
        guard !values.isEmpty else {
            await record(.warning, "For Each block has no values — skipping")
            return
        }
        guard !body.isEmpty else {
            await record(.warning, "For Each block has no children — skipping")
            return
        }

        for (idx, value) in values.enumerated() {
            try Task.checkCancellation()
            setDetail(parentStepId, "\(idx + 1)/\(values.count): \(value)")
            await record(.info, "Iteration \(idx + 1)/\(values.count): \(value)")
            // Save / restore the bound value so siblings after this
            // forEach see the pre-loop value, not the last iteration's.
            // (Other context fields persist normally.)
            var inner = context
            apply(&inner, value)
            try await execute(steps: body, context: &inner, runGroupId: nil)
        }
    }

    // MARK: - Management steps

    private func runUnload(context: ExecutionContext) async throws {
        guard let backend = context.backend else {
            await record(.warning, "Unload Model with no Set Backend; skipping")
            return
        }
        guard backend.type == .ollama else {
            await record(.warning, "Unload Model is Ollama-only; skipping on \(backend.type.displayName)")
            return
        }
        guard let model = context.model, !model.isEmpty else {
            await record(.warning, "Unload Model with no model set; skipping")
            return
        }
        do {
            try await inferenceService.ollamaClient.unloadModel(model)
            await record(.success, "Unloaded \(model)")
        } catch {
            await record(.warning, "Unload failed: \(error.localizedDescription)")
        }
    }

    private func runCoolDown(mode: CoolDownMode) async throws {
        switch mode {
        case .fixed(let seconds):
            await record(.info, "Cooling down for \(seconds)s…")
            try await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000)
        case .thermal(let timeout):
            await record(.info, "Cooling down until thermal nominal (max \(timeout)s)…")
            let deadline = Date().addingTimeInterval(Double(max(10, timeout)))
            while Date() < deadline {
                try Task.checkCancellation()
                if ProcessInfo.processInfo.thermalState == .nominal {
                    await record(.success, "Thermal nominal — proceeding")
                    return
                }
                // Poll once a second — coarse enough not to thrash,
                // fine enough that we resume within a thermal step.
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            await record(.warning, "Cool Down timed out — thermal still elevated; proceeding")
        }
    }

    // MARK: - Progress tracking

    private func initializeProgress(steps: [FlowStep]) {
        for step in steps {
            progress[step.id] = StepProgress(id: step.id, status: .pending)
            if let children = step.kind.children {
                initializeProgress(steps: children)
            }
        }
    }

    private func markRunning(_ id: UUID) {
        guard var p = progress[id] else { return }
        p.status = .running
        p.startedAt = Date()
        progress[id] = p
    }

    private func markCompleted(_ id: UUID) {
        guard var p = progress[id] else { return }
        p.status = .completed
        p.endedAt = Date()
        progress[id] = p
    }

    private func markFailed(_ id: UUID, _ reason: String) {
        guard var p = progress[id] else { return }
        p.status = .failed(reason)
        p.endedAt = Date()
        progress[id] = p
    }

    private func setDetail(_ id: UUID, _ detail: String) {
        guard var p = progress[id] else { return }
        p.detail = detail
        progress[id] = p
    }

    // MARK: - Logging

    private func record(_ level: LogEntry.Level, _ message: String) async {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        log.append(entry)
        // Cap log length to keep memory bounded on long flows.
        if log.count > 500 {
            log.removeFirst(log.count - 500)
        }
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
