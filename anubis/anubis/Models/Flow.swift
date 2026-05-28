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

    static let `default` = FlowParameters(
        temperature: 0.7,
        topP: 0.9,
        maxTokens: 512,
        seedStrategy: .random,
        fixedSeed: nil
    )
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
