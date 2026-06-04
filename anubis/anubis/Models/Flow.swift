//
//  Flow.swift
//  anubis
//
//  A Flow is a user-authored sequence of benchmark steps — the data
//  layer for the Shortcuts-style "Flows" tab. Each Flow is persisted
//  as a single row with the step tree serialized as JSON in
//  steps_json. Step trees are nested (containers like repeatN and
//  forEachModel hold children), reordered constantly in the editor,
//  and rarely queried structurally — JSON beats normalized rows for
//  this access pattern, with the only downside being no SQL-level
//  filtering of step types (which we don't need).
//
//  A *single execution* of a Flow lives in FlowRun (separate file)
//  and tags every BenchmarkSession it produces via run.flow_run_id.
//

import Foundation
@preconcurrency import GRDB

// MARK: - Supporting Types

/// Reference to a backend captured inside a Flow step. For Ollama /
/// Apple Intelligence the type alone is enough; for an
/// OpenAI-compatible backend we also pin the configuration UUID so
/// the right server is targeted at execution time.
struct FlowBackendRef: Codable, Hashable {
    var type: InferenceBackendType
    var openAIConfigId: UUID?
}

/// Where a prompt step gets its text. `inline` is free text typed
/// into the editor; `library` references one of the curated benchmark
/// prompts by stable identifier; `file` is reserved for a future
/// security-scoped bookmark to a .txt on disk (not surfaced in v1 UI
/// but the case is wired so adding it later is non-breaking).
enum FlowPromptSource: Codable, Hashable {
    case inline(text: String)
    case library(id: String)
    case file(bookmarkData: Data, displayName: String)
}

/// Sampler / generation parameters captured per-step. Mirrors the
/// fields surfaced in the Benchmark tab's Parameters disclosure so a
/// step is a drop-in replacement for the existing single-run UI.
struct FlowParameters: Codable, Hashable {
    var temperature: Double
    var topP: Double
    var maxTokens: Int
    var seedStrategy: SeedStrategy
    var fixedSeed: Int64?
    /// Thinking toggle (Ollama `think` / oMLX `enable_thinking`). Auto omits it.
    var thinkMode: OllamaThinkMode

    static let `default` = FlowParameters(
        temperature: 0.7,
        topP: 0.9,
        maxTokens: 512,
        seedStrategy: .random,
        fixedSeed: nil,
        thinkMode: .auto
    )

    init(
        temperature: Double,
        topP: Double,
        maxTokens: Int,
        seedStrategy: SeedStrategy,
        fixedSeed: Int64?,
        thinkMode: OllamaThinkMode = .auto
    ) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.seedStrategy = seedStrategy
        self.fixedSeed = fixedSeed
        self.thinkMode = thinkMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        temperature = try c.decode(Double.self, forKey: .temperature)
        topP = try c.decode(Double.self, forKey: .topP)
        maxTokens = try c.decode(Int.self, forKey: .maxTokens)
        seedStrategy = try c.decode(SeedStrategy.self, forKey: .seedStrategy)
        fixedSeed = try c.decodeIfPresent(Int64.self, forKey: .fixedSeed)
        // Backward compatible: flows saved before the thinking toggle existed.
        thinkMode = (try? c.decode(OllamaThinkMode.self, forKey: .thinkMode)) ?? .auto
    }
}

/// Cool-down behaviour between heavy runs. `.thermal` blocks until
/// ProcessInfo reports `.nominal` again (with a safety timeout so the
/// flow can't wedge if the sensor stays warm forever). `.fixed` waits
/// a wall-clock duration regardless.
enum CoolDownMode: Codable, Hashable {
    case thermal(timeoutSeconds: Int)
    case fixed(seconds: Int)
}

// MARK: - FlowStep

/// One node in a flow's step tree. The wrapper struct gives every
/// step a stable identity for SwiftUI's diffing (ForEach, drag/drop)
/// even as `kind` mutates. JSON serialization is synthesized for
/// both the struct and the indirect enum.
struct FlowStep: Identifiable, Codable, Hashable {
    var id: UUID
    var kind: FlowStepKind

    init(id: UUID = UUID(), kind: FlowStepKind) {
        self.id = id
        self.kind = kind
    }
}

/// The variant payload for a FlowStep. Indirect because the
/// container cases recursively hold `[FlowStep]` children.
indirect enum FlowStepKind: Codable, Hashable {
    // State-setting steps mutate the executor's ExecutionContext.
    case setBackend(FlowBackendRef)
    case setModel(String)
    case setPrompt(FlowPromptSource)
    case setParameters(FlowParameters)

    // Action: produces a BenchmarkSession from the current context.
    case runBenchmark

    // Containers: re-run their body N times / once per iteration value.
    case repeatN(count: Int, body: [FlowStep])
    case forEachModel(models: [String], body: [FlowStep])
    case forEachPrompt(prompts: [String], body: [FlowStep])

    // Management steps. unloadModel is Ollama-only at runtime (no-op
    // for other backends with a yellow badge in the editor).
    case unloadModel
    case resetConnection
    case coolDown(CoolDownMode)
    case annotate(text: String)
}

// MARK: - FlowStepKind UI helpers

extension FlowStepKind {
    /// Multiplier this step contributes to the parent's run count.
    /// See `Array<FlowStep>.expectedRunCount` for semantics.
    var expectedRunCount: Int {
        switch self {
        case .runBenchmark:
            return 1
        case .repeatN(let count, let body):
            return max(0, count) * body.expectedRunCount
        case .forEachModel(let values, let body):
            return values.count * body.expectedRunCount
        case .forEachPrompt(let values, let body):
            return values.count * body.expectedRunCount
        default:
            return 0
        }
    }

    /// Whether this step has a child body (for nesting in the editor).
    var isContainer: Bool {
        switch self {
        case .repeatN, .forEachModel, .forEachPrompt: return true
        default: return false
        }
    }

    /// Read access to the child body, if any.
    var children: [FlowStep]? {
        switch self {
        case .repeatN(_, let body),
             .forEachModel(_, let body),
             .forEachPrompt(_, let body):
            return body
        default:
            return nil
        }
    }

    /// Replace the child body of a container. No-op for non-containers
    /// — callers should check `isContainer` first.
    mutating func setChildren(_ newBody: [FlowStep]) {
        switch self {
        case .repeatN(let count, _):
            self = .repeatN(count: count, body: newBody)
        case .forEachModel(let models, _):
            self = .forEachModel(models: models, body: newBody)
        case .forEachPrompt(let prompts, _):
            self = .forEachPrompt(prompts: prompts, body: newBody)
        default:
            break
        }
    }

    /// Display name for the palette and step rows.
    var displayName: String {
        switch self {
        case .setBackend: return "Set Backend"
        case .setModel: return "Set Model"
        case .setPrompt: return "Set Prompt"
        case .setParameters: return "Set Parameters"
        case .runBenchmark: return "Run Benchmark"
        case .repeatN: return "Repeat"
        case .forEachModel: return "For Each Model"
        case .forEachPrompt: return "For Each Prompt"
        case .unloadModel: return "Unload Model"
        case .resetConnection: return "Reset Connection"
        case .coolDown: return "Cool Down"
        case .annotate: return "Annotate"
        }
    }

    /// SF Symbol for the palette and step rows.
    var iconName: String {
        switch self {
        case .setBackend: return "server.rack"
        case .setModel: return "cube.box"
        case .setPrompt: return "text.bubble"
        case .setParameters: return "slider.horizontal.3"
        case .runBenchmark: return "play.fill"
        case .repeatN: return "repeat"
        case .forEachModel: return "rectangle.stack"
        case .forEachPrompt: return "text.append"
        case .unloadModel: return "eject"
        case .resetConnection: return "arrow.triangle.2.circlepath"
        case .coolDown: return "snowflake"
        case .annotate: return "note.text"
        }
    }
}

// MARK: - Flow record

/// A saved flow definition. Persisted as a single row; the step tree
/// lives in `steps_json` as encoded `[FlowStep]`.
struct Flow: Identifiable, Codable, Hashable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "flow"

    var id: Int64?
    var name: String
    var notes: String?
    var stepsJSON: String
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case name
        case notes
        case stepsJSON = "steps_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(name: String, steps: [FlowStep] = []) {
        self.id = nil
        self.name = name
        self.notes = nil
        self.stepsJSON = Self.encode(steps)
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: Step accessor

    /// Decoded view of the step tree. Reading is failure-tolerant
    /// (returns [] on parse failure rather than throwing) so a
    /// corrupted row doesn't crash the editor — the user can wipe and
    /// rebuild without losing access to the rest of their flows.
    var steps: [FlowStep] {
        get { Self.decode(stepsJSON) }
        set {
            stepsJSON = Self.encode(newValue)
            updatedAt = Date()
        }
    }

    // MARK: Codec

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder = JSONDecoder()

    static func encode(_ steps: [FlowStep]) -> String {
        guard let data = try? encoder.encode(steps),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    static func decode(_ json: String) -> [FlowStep] {
        guard let data = json.data(using: .utf8),
              let steps = try? decoder.decode([FlowStep].self, from: data) else {
            return []
        }
        return steps
    }
}

// MARK: - Database Operations

extension Flow {
    /// All saved flows, most recently updated first.
    static func fetchAll(db: Database) throws -> [Flow] {
        try Flow.order(Column("updated_at").desc).fetchAll(db)
    }

    static func fetchByID(db: Database, id: Int64) throws -> Flow? {
        try Flow.fetchOne(db, key: id)
    }
}

// MARK: - Tree mutation primitives

/// Path through the step tree. `[2, 1, 0]` means root[2].children[1].children[0].
typealias FlowStepPath = IndexPath

extension Array where Element == FlowStep {
    /// Read-only step at a path. Returns nil for invalid paths or
    /// paths into non-container children.
    func step(at path: FlowStepPath) -> FlowStep? {
        guard let first = path.first, first >= 0, first < count else { return nil }
        if path.count == 1 { return self[first] }
        guard let children = self[first].kind.children else { return nil }
        return children.step(at: path.dropFirst().asIndexPath)
    }

    /// Remove and return the step at `path`. No-op for invalid paths.
    @discardableResult
    mutating func removeStep(at path: FlowStepPath) -> FlowStep? {
        guard let first = path.first, first >= 0, first < count else { return nil }
        if path.count == 1 {
            return self.remove(at: first)
        }
        guard var children = self[first].kind.children else { return nil }
        let removed = children.removeStep(at: path.dropFirst().asIndexPath)
        self[first].kind.setChildren(children)
        return removed
    }

    /// Insert `step` so it ends up at `path` (i.e. `path.last` is the
    /// position in its parent's array). Indices past the end are
    /// clamped to append. No-op if any non-leaf path segment doesn't
    /// resolve to a container.
    mutating func insertStep(_ step: FlowStep, at path: FlowStepPath) {
        guard let first = path.first, first >= 0 else { return }
        if path.count == 1 {
            let clamped = Swift.min(first, count)
            self.insert(step, at: clamped)
            return
        }
        guard first < count, self[first].kind.isContainer,
              var children = self[first].kind.children else { return }
        children.insertStep(step, at: path.dropFirst().asIndexPath)
        self[first].kind.setChildren(children)
    }

    /// Apply `transform` to the step at `path`. No-op for invalid
    /// paths.
    mutating func updateStep(at path: FlowStepPath, _ transform: (inout FlowStep) -> Void) {
        guard let first = path.first, first >= 0, first < count else { return }
        if path.count == 1 {
            transform(&self[first])
            return
        }
        guard var children = self[first].kind.children else { return }
        children.updateStep(at: path.dropFirst().asIndexPath, transform)
        self[first].kind.setChildren(children)
    }

    /// Swap siblings within the same parent. `path` is the step to
    /// move; `delta` is +1 (down) or -1 (up). No-op if the move would
    /// fall off either end.
    mutating func moveSibling(at path: FlowStepPath, by delta: Int) {
        guard let last = path.last else { return }
        let parentPath = path.dropLast().asIndexPath
        // Read siblings via a transient remove/insert into a holder
        // — keeps the recursive path resolution centralized.
        let target = last + delta
        if parentPath.isEmpty {
            guard target >= 0, target < count else { return }
            let item = self.remove(at: last)
            self.insert(item, at: target)
        } else {
            guard let parent = step(at: parentPath),
                  var children = parent.kind.children else { return }
            guard target >= 0, target < children.count else { return }
            let item = children.remove(at: last)
            children.insert(item, at: target)
            updateStep(at: parentPath) { step in
                step.kind.setChildren(children)
            }
        }
    }

    /// Recursive search for the path of a step by id.
    func path(forID id: UUID) -> FlowStepPath? {
        for (i, step) in enumerated() {
            if step.id == id { return [i] }
            if let children = step.kind.children,
               let nested = children.path(forID: id) {
                var p: FlowStepPath = [i]
                p.append(nested)
                return p
            }
        }
        return nil
    }

    /// Sum of `runBenchmark` invocations a full execution would
    /// produce, multiplied through container cardinalities. Empty
    /// containers contribute zero — running an empty repeat or an
    /// empty for-each is a no-op at runtime. Used by the editor's
    /// "N runs" chip and the run sheet's "X of Y" counter.
    ///
    /// Container semantics:
    /// - `repeatN(count, body)` → `count * expectedRunCount(body)`
    /// - `forEachModel(models, body)` → `models.count * expectedRunCount(body)`
    /// - `forEachPrompt(prompts, body)` → `prompts.count * expectedRunCount(body)`
    /// - `runBenchmark` → 1
    /// - everything else → 0
    var expectedRunCount: Int {
        reduce(0) { $0 + $1.kind.expectedRunCount }
    }

    /// Most-recent `setBackend` step in document order at or before
    /// the step with the given id — i.e. the backend that *would be*
    /// in effect when execution reaches that step. Walks the tree
    /// depth-first, pre-order so a setBackend in an earlier sibling
    /// (or in an enclosing container that ran before) is honored.
    /// Returns nil if no setBackend precedes the target.
    func impliedBackend(beforeStepID id: UUID) -> FlowBackendRef? {
        var current: FlowBackendRef?
        _ = Self.walkLookingForBackend(steps: self, target: id, current: &current)
        return current
    }

    /// Depth-first walker. Returns true once `target` is found so the
    /// caller stops mutating `current`.
    private static func walkLookingForBackend(
        steps: [FlowStep],
        target: UUID,
        current: inout FlowBackendRef?
    ) -> Bool {
        for step in steps {
            if step.id == target { return true }
            if case .setBackend(let ref) = step.kind {
                current = ref
            }
            if let children = step.kind.children {
                if walkLookingForBackend(steps: children, target: target, current: &current) {
                    return true
                }
            }
        }
        return false
    }
}

// IndexPath.dropFirst() returns IndexPath.SubSequence — which on
// Foundation is `IndexPath` itself, but the compiler still wants an
// explicit bridge through Array<Int> in our recursive call sites.
private extension IndexPath.SubSequence {
    var asIndexPath: IndexPath { IndexPath(indexes: Array(self)) }
}

// MARK: - Lint

/// A static check failure found in a flow's step tree.
struct FlowWarning: Identifiable, Hashable {
    let id = UUID()
    /// The offending step's id (so the editor can render the badge
    /// next to that row).
    let stepID: UUID
    let kind: Kind

    enum Kind: Hashable {
        /// Set Backend / Model / Prompt followed by no Run Benchmark
        /// before the next override of that kind or end-of-flow.
        case danglingSetBackend
        case danglingSetModel
        case danglingSetPrompt
        /// Set step's payload is blank — runs depending on it will
        /// throw at execution time.
        case setModelEmpty
        case setPromptEmpty
        /// Set Prompt source isn't supported yet (library / file).
        case setPromptUnsupportedSource
        /// For Each contains an entry that's blank/whitespace — that
        /// iteration will fail at runtime.
        case forEachEmptyEntry(index: Int)
        /// Run Benchmark reached without a preceding state setter.
        case runMissingBackend
        case runMissingModel
        case runMissingPrompt
        /// Container with no children.
        case emptyContainer
        /// For Each with an empty values list (won't iterate, won't run).
        case emptyForEachValues
    }

    var message: String {
        switch kind {
        case .danglingSetBackend:
            return "Set Backend has no Run Benchmark after it — the backend choice is never used."
        case .danglingSetModel:
            return "Set Model has no Run Benchmark after it — the model choice is never used."
        case .danglingSetPrompt:
            return "Set Prompt has no Run Benchmark after it — the prompt is never used."
        case .setModelEmpty:
            return "Set Model has no model name — any Run Benchmark using it will fail at run time."
        case .setPromptEmpty:
            return "Set Prompt has no text — any Run Benchmark using it will fail at run time."
        case .setPromptUnsupportedSource:
            return "Set Prompt is using a source type (library/file) that isn't wired up yet — only inline text runs today."
        case .forEachEmptyEntry(let index):
            return "For Each entry #\(index + 1) is blank — that iteration will fail at run time."
        case .runMissingBackend:
            return "Run Benchmark needs a Set Backend step before it."
        case .runMissingModel:
            return "Run Benchmark needs a Set Model step (or a For Each Model wrapper) before it."
        case .runMissingPrompt:
            return "Run Benchmark needs a Set Prompt step (or a For Each Prompt wrapper) before it."
        case .emptyContainer:
            return "Container has no child steps — it'll be skipped at run time."
        case .emptyForEachValues:
            return "For Each has no values — add at least one model or prompt or the loop won't run."
        }
    }
}

extension Array where Element == FlowStep {
    /// Run the lint walker over this tree and return every warning
    /// found, paired with the offending step's id.
    func lintWarnings() -> [FlowWarning] {
        var state = LintState()
        var warnings: [FlowWarning] = []
        Self.lintWalk(steps: self, state: &state, warnings: &warnings)
        Self.flushDanglingSets(state: state, warnings: &warnings)
        return warnings
    }

    /// `lintWarnings()` keyed by step id for cheap row lookup.
    func lintWarningsByStepID() -> [UUID: [FlowWarning]] {
        Dictionary(grouping: lintWarnings(), by: { $0.stepID })
    }

    // MARK: Internals

    /// Mutable state threaded through the walker. Tracks the most
    /// recent Set step of each kind whose value hasn't been consumed
    /// by a Run Benchmark yet, plus a "have we ever seen any Set of
    /// this kind" flag so we can flag Runs that come too early.
    fileprivate struct LintState {
        var lastBackendSetID: UUID?
        var lastModelSetID: UUID?
        var lastPromptSetID: UUID?

        var sawBackend: Bool = false
        var sawModel: Bool = false
        var sawPrompt: Bool = false
    }

    /// Depth-first pre-order walk. The state is in-out so nested
    /// containers naturally inherit and update the outer context.
    fileprivate static func lintWalk(
        steps: [FlowStep],
        state: inout LintState,
        warnings: inout [FlowWarning]
    ) {
        for step in steps {
            switch step.kind {
            case .setBackend:
                if let prev = state.lastBackendSetID {
                    warnings.append(FlowWarning(stepID: prev, kind: .danglingSetBackend))
                }
                state.lastBackendSetID = step.id
                state.sawBackend = true

            case .setModel(let name):
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    warnings.append(FlowWarning(stepID: step.id, kind: .setModelEmpty))
                }
                if let prev = state.lastModelSetID {
                    warnings.append(FlowWarning(stepID: prev, kind: .danglingSetModel))
                }
                state.lastModelSetID = step.id
                // Mark seen even when empty — the user *intended* to set
                // a model; the downstream warning belongs on this step,
                // not on every Run after it.
                state.sawModel = true

            case .setPrompt(let source):
                switch source {
                case .inline(let text):
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        warnings.append(FlowWarning(stepID: step.id, kind: .setPromptEmpty))
                    }
                case .library, .file:
                    // The executor logs these as no-ops today; flag at
                    // lint so the user isn't surprised.
                    warnings.append(FlowWarning(stepID: step.id, kind: .setPromptUnsupportedSource))
                }
                if let prev = state.lastPromptSetID {
                    warnings.append(FlowWarning(stepID: prev, kind: .danglingSetPrompt))
                }
                state.lastPromptSetID = step.id
                state.sawPrompt = true

            case .setParameters:
                // Parameters have implicit defaults — never a lint hit.
                break

            case .runBenchmark:
                if !state.sawBackend {
                    warnings.append(FlowWarning(stepID: step.id, kind: .runMissingBackend))
                }
                if !state.sawModel {
                    warnings.append(FlowWarning(stepID: step.id, kind: .runMissingModel))
                }
                if !state.sawPrompt {
                    warnings.append(FlowWarning(stepID: step.id, kind: .runMissingPrompt))
                }
                // Consume — any preceding Set steps are now "used".
                state.lastBackendSetID = nil
                state.lastModelSetID = nil
                state.lastPromptSetID = nil

            case .repeatN(_, let body):
                if body.isEmpty {
                    warnings.append(FlowWarning(stepID: step.id, kind: .emptyContainer))
                } else {
                    lintWalk(steps: body, state: &state, warnings: &warnings)
                }

            case .forEachModel(let values, let body):
                // For Each Model overrides the outer model for each
                // iteration, so a Set Model before this container is
                // dangling — its value never reaches a Run Benchmark.
                if let prev = state.lastModelSetID {
                    warnings.append(FlowWarning(stepID: prev, kind: .danglingSetModel))
                }
                state.lastModelSetID = nil
                state.sawModel = true  // the container provides the model

                if values.isEmpty {
                    warnings.append(FlowWarning(stepID: step.id, kind: .emptyForEachValues))
                } else {
                    for (idx, v) in values.enumerated()
                    where v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        warnings.append(FlowWarning(stepID: step.id, kind: .forEachEmptyEntry(index: idx)))
                    }
                }
                if body.isEmpty {
                    warnings.append(FlowWarning(stepID: step.id, kind: .emptyContainer))
                } else if !values.isEmpty {
                    lintWalk(steps: body, state: &state, warnings: &warnings)
                }

            case .forEachPrompt(let values, let body):
                if let prev = state.lastPromptSetID {
                    warnings.append(FlowWarning(stepID: prev, kind: .danglingSetPrompt))
                }
                state.lastPromptSetID = nil
                state.sawPrompt = true

                if values.isEmpty {
                    warnings.append(FlowWarning(stepID: step.id, kind: .emptyForEachValues))
                } else {
                    for (idx, v) in values.enumerated()
                    where v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        warnings.append(FlowWarning(stepID: step.id, kind: .forEachEmptyEntry(index: idx)))
                    }
                }
                if body.isEmpty {
                    warnings.append(FlowWarning(stepID: step.id, kind: .emptyContainer))
                } else if !values.isEmpty {
                    lintWalk(steps: body, state: &state, warnings: &warnings)
                }

            case .unloadModel, .resetConnection, .coolDown, .annotate:
                // These don't affect the dangling-set bookkeeping.
                break
            }
        }
    }

    /// At end-of-flow, any Set step still in flight was never
    /// consumed by a Run Benchmark — emit one dangling warning each.
    fileprivate static func flushDanglingSets(
        state: LintState,
        warnings: inout [FlowWarning]
    ) {
        if let prev = state.lastBackendSetID {
            warnings.append(FlowWarning(stepID: prev, kind: .danglingSetBackend))
        }
        if let prev = state.lastModelSetID {
            warnings.append(FlowWarning(stepID: prev, kind: .danglingSetModel))
        }
        if let prev = state.lastPromptSetID {
            warnings.append(FlowWarning(stepID: prev, kind: .danglingSetPrompt))
        }
    }
}
