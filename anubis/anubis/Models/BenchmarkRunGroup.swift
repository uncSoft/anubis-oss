//
//  BenchmarkRunGroup.swift
//  anubis
//
//  Represents N repetitions of the same benchmark configuration, run
//  sequentially. Aggregate statistics (mean, stdev, 95% bootstrap CI)
//  are computed once at group completion and persisted — used by the
//  Reports view and leaderboard so single-number-with-CI is the
//  default display rather than N raw numbers.
//

import Foundation
@preconcurrency import GRDB

/// Seed strategy controls per-run sampler determinism.
///
/// - `random`: each repetition picks a fresh random seed. The bootstrap
///   CI then captures *both* hardware variance (thermal, scheduling,
///   cache) *and* sampler variance (different output text per run).
///   This is the honest measurement of what an end user actually
///   experiences across a chat session — and the default.
/// - `fixed`: every repetition uses the same explicit seed, so output
///   is byte-identical. CI then captures only hardware variance. Useful
///   for tight reproducibility runs and for comparing two configs
///   without sampler noise muddying the result.
enum SeedStrategy: String, Codable, DatabaseValueConvertible {
    case random
    case fixed
}

/// A group of N benchmark sessions sharing the same configuration,
/// run sequentially. Persists aggregate stats at group completion so
/// reports + leaderboard can display mean ± 95% CI directly.
struct BenchmarkRunGroup: Identifiable, Codable, Hashable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "benchmark_run_group"

    var id: Int64?
    var createdAt: Date
    var completedAt: Date?
    var status: BenchmarkStatus

    // Config snapshot (so the group is meaningful even if the
    // referenced model is later deleted from the backend).
    var modelId: String
    var modelName: String
    var modelQuantization: String?
    var modelFormat: String?
    var backend: String
    var prompt: String

    // Sampler / generation params shared across all reps.
    var temperature: Double
    var topP: Double
    var maxTokens: Int
    var seedStrategy: SeedStrategy
    var fixedSeed: Int64?

    // Repetition counts. completedRepetitions ≤ repetitions; a group
    // can be "completed" with fewer than target if some runs failed
    // or were cancelled.
    var repetitions: Int
    var completedRepetitions: Int

    // MARK: - Aggregate stats (populated at group completion).
    //
    // n equals completedRepetitions (and is also stored so leaderboard
    // submissions don't have to recompute from joined sessions). Each
    // metric carries mean, sample standard deviation, and 95%
    // bootstrap CI bounds. All nullable so partial groups don't
    // require synthetic values.

    var sampleCount: Int?

    var meanTokensPerSecond: Double?
    var stdevTokensPerSecond: Double?
    var ciLowTokensPerSecond: Double?
    var ciHighTokensPerSecond: Double?

    var meanTimeToFirstToken: Double?
    var stdevTimeToFirstToken: Double?
    var ciLowTimeToFirstToken: Double?
    var ciHighTimeToFirstToken: Double?

    var meanWattsPerToken: Double?
    var stdevWattsPerToken: Double?
    var ciLowWattsPerToken: Double?
    var ciHighWattsPerToken: Double?

    var meanSystemPowerWatts: Double?
    var stdevSystemPowerWatts: Double?
    var ciLowSystemPowerWatts: Double?
    var ciHighSystemPowerWatts: Double?

    var meanPeakMemoryBytes: Double?
    var stdevPeakMemoryBytes: Double?
    var ciLowPeakMemoryBytes: Double?
    var ciHighPeakMemoryBytes: Double?

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case createdAt = "created_at"
        case completedAt = "completed_at"
        case status
        case modelId = "model_id"
        case modelName = "model_name"
        case modelQuantization = "model_quantization"
        case modelFormat = "model_format"
        case backend
        case prompt
        case temperature
        case topP = "top_p"
        case maxTokens = "max_tokens"
        case seedStrategy = "seed_strategy"
        case fixedSeed = "fixed_seed"
        case repetitions
        case completedRepetitions = "completed_repetitions"
        case sampleCount = "sample_count"
        case meanTokensPerSecond = "mean_tokens_per_second"
        case stdevTokensPerSecond = "stdev_tokens_per_second"
        case ciLowTokensPerSecond = "ci_low_tokens_per_second"
        case ciHighTokensPerSecond = "ci_high_tokens_per_second"
        case meanTimeToFirstToken = "mean_time_to_first_token"
        case stdevTimeToFirstToken = "stdev_time_to_first_token"
        case ciLowTimeToFirstToken = "ci_low_time_to_first_token"
        case ciHighTimeToFirstToken = "ci_high_time_to_first_token"
        case meanWattsPerToken = "mean_watts_per_token"
        case stdevWattsPerToken = "stdev_watts_per_token"
        case ciLowWattsPerToken = "ci_low_watts_per_token"
        case ciHighWattsPerToken = "ci_high_watts_per_token"
        case meanSystemPowerWatts = "mean_system_power_watts"
        case stdevSystemPowerWatts = "stdev_system_power_watts"
        case ciLowSystemPowerWatts = "ci_low_system_power_watts"
        case ciHighSystemPowerWatts = "ci_high_system_power_watts"
        case meanPeakMemoryBytes = "mean_peak_memory_bytes"
        case stdevPeakMemoryBytes = "stdev_peak_memory_bytes"
        case ciLowPeakMemoryBytes = "ci_low_peak_memory_bytes"
        case ciHighPeakMemoryBytes = "ci_high_peak_memory_bytes"
    }

    /// Initialise a new group in `planned` state.
    init(
        modelId: String,
        modelName: String,
        backend: InferenceBackendType,
        prompt: String,
        modelQuantization: String? = nil,
        modelFormat: String? = nil,
        temperature: Double,
        topP: Double,
        maxTokens: Int,
        seedStrategy: SeedStrategy = .random,
        fixedSeed: Int64? = nil,
        repetitions: Int
    ) {
        self.id = nil
        self.createdAt = Date()
        self.completedAt = nil
        self.status = .running
        self.modelId = modelId
        self.modelName = modelName
        self.modelQuantization = modelQuantization
        self.modelFormat = modelFormat
        self.backend = backend.rawValue
        self.prompt = prompt
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.seedStrategy = seedStrategy
        self.fixedSeed = fixedSeed
        self.repetitions = repetitions
        self.completedRepetitions = 0
        self.sampleCount = nil
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Database Operations

extension BenchmarkRunGroup {
    static func fetchByID(db: Database, id: Int64) throws -> BenchmarkRunGroup? {
        try BenchmarkRunGroup.fetchOne(db, key: id)
    }

    /// All sessions belonging to this group, ordered by start time.
    func sessions(db: Database) throws -> [BenchmarkSession] {
        try BenchmarkSession
            .filter(Column("run_group_id") == id)
            .order(Column("started_at"))
            .fetchAll(db)
    }
}

// MARK: - Aggregation

extension BenchmarkRunGroup {
    /// Populate aggregate stats (mean/stdev/95% bootstrap CI) from the
    /// completed sessions belonging to this group. Called once at
    /// group completion.
    ///
    /// Sessions with status != .completed are excluded — failed and
    /// cancelled runs would skew the distribution. sampleCount is set
    /// to the count of contributing sessions.
    mutating func recomputeAggregates(from sessions: [BenchmarkSession]) {
        let completed = sessions.filter { $0.status == .completed }
        sampleCount = completed.count

        let tps = completed.compactMap { $0.tokensPerSecond }
        meanTokensPerSecond = BootstrapCI.mean(tps)
        stdevTokensPerSecond = BootstrapCI.stdev(tps)
        if let ci = BootstrapCI.confidenceInterval95(tps) {
            ciLowTokensPerSecond = ci.low
            ciHighTokensPerSecond = ci.high
        }

        let ttft = completed.compactMap { $0.timeToFirstToken }
        meanTimeToFirstToken = BootstrapCI.mean(ttft)
        stdevTimeToFirstToken = BootstrapCI.stdev(ttft)
        if let ci = BootstrapCI.confidenceInterval95(ttft) {
            ciLowTimeToFirstToken = ci.low
            ciHighTimeToFirstToken = ci.high
        }

        let jpt = completed.compactMap { $0.avgWattsPerToken }
        meanWattsPerToken = BootstrapCI.mean(jpt)
        stdevWattsPerToken = BootstrapCI.stdev(jpt)
        if let ci = BootstrapCI.confidenceInterval95(jpt) {
            ciLowWattsPerToken = ci.low
            ciHighWattsPerToken = ci.high
        }

        let sysPwr = completed.compactMap { $0.avgSystemPowerWatts }
        meanSystemPowerWatts = BootstrapCI.mean(sysPwr)
        stdevSystemPowerWatts = BootstrapCI.stdev(sysPwr)
        if let ci = BootstrapCI.confidenceInterval95(sysPwr) {
            ciLowSystemPowerWatts = ci.low
            ciHighSystemPowerWatts = ci.high
        }

        let peakMem = completed.compactMap { $0.peakMemoryBytes.map(Double.init) }
        meanPeakMemoryBytes = BootstrapCI.mean(peakMem)
        stdevPeakMemoryBytes = BootstrapCI.stdev(peakMem)
        if let ci = BootstrapCI.confidenceInterval95(peakMem) {
            ciLowPeakMemoryBytes = ci.low
            ciHighPeakMemoryBytes = ci.high
        }
    }
}
