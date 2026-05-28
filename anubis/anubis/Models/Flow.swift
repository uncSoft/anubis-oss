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
