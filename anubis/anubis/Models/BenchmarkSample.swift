//
//  BenchmarkSample.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation
@preconcurrency import GRDB

/// A time-series sample of metrics during a benchmark
struct BenchmarkSample: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "benchmark_sample"

    var id: Int64?
    var sessionId: Int64
    var timestamp: Date
    var gpuUtilization: Double?
    var cpuUtilization: Double?
    var anePowerWatts: Double?
    var memoryUsedBytes: Int64?
    var memoryTotalBytes: Int64?
    var thermalState: Int?
    var tokensGenerated: Int?
    var cumulativeTokensPerSecond: Double?

    // v4 power/frequency columns
    var gpuPowerWatts: Double?
    var cpuPowerWatts: Double?
    var dramPowerWatts: Double?
    var systemPowerWatts: Double?
    var gpuFrequencyMHz: Double?
    var backendProcessMemoryBytes: Int64?
    var backendProcessCPUPercent: Double?
    var wattsPerToken: Double?

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case sessionId = "session_id"
        case timestamp
        case gpuUtilization = "gpu_utilization"
        case cpuUtilization = "cpu_utilization"
        case anePowerWatts = "ane_power_watts"
        case memoryUsedBytes = "memory_used_bytes"
        case memoryTotalBytes = "memory_total_bytes"
        case thermalState = "thermal_state"
        case tokensGenerated = "tokens_generated"
        case cumulativeTokensPerSecond = "cumulative_tokens_per_second"
        case gpuPowerWatts = "gpu_power_watts"
        case cpuPowerWatts = "cpu_power_watts"
        case dramPowerWatts = "dram_power_watts"
        case systemPowerWatts = "system_power_watts"
        case gpuFrequencyMHz = "gpu_frequency_mhz"
        case backendProcessMemoryBytes = "backend_process_memory_bytes"
        case backendProcessCPUPercent = "backend_process_cpu_percent"
        case wattsPerToken = "watts_per_token"
    }

    /// Create a sample from current metrics
    init(
        sessionId: Int64,
        metrics: SystemMetrics,
        tokensGenerated: Int? = nil,
        cumulativeTokensPerSecond: Double? = nil
    ) {
        self.id = nil
        self.sessionId = sessionId
        self.timestamp = metrics.timestamp
        self.gpuUtilization = metrics.gpuUtilization
        self.cpuUtilization = metrics.cpuUtilization
        self.anePowerWatts = metrics.anePowerWatts
        self.memoryUsedBytes = metrics.memoryUsedBytes
        self.memoryTotalBytes = metrics.memoryTotalBytes
        self.thermalState = metrics.thermalState.rawValue
        self.tokensGenerated = tokensGenerated
        self.cumulativeTokensPerSecond = cumulativeTokensPerSecond

        // v4 power fields from extended SystemMetrics
        self.gpuPowerWatts = metrics.gpuPowerWatts
        self.cpuPowerWatts = metrics.cpuPowerWatts
        self.dramPowerWatts = metrics.dramPowerWatts
        self.systemPowerWatts = metrics.systemPowerWatts
        self.gpuFrequencyMHz = metrics.gpuFrequencyMHz
        self.backendProcessMemoryBytes = metrics.backendProcessMemoryBytes
        self.backendProcessCPUPercent = metrics.backendProcessCPUPercent

        // Compute watts per token: system power / current tok/s
        if let power = metrics.systemPowerWatts, power > 0,
           let tps = cumulativeTokensPerSecond, tps > 0 {
            self.wattsPerToken = power / tps
        } else {
            self.wattsPerToken = nil
        }
    }

    /// Create from raw values
    init(
        sessionId: Int64,
        timestamp: Date = Date(),
        gpuUtilization: Double? = nil,
        cpuUtilization: Double? = nil,
        anePowerWatts: Double? = nil,
        memoryUsedBytes: Int64? = nil,
        memoryTotalBytes: Int64? = nil,
        thermalState: Int? = nil,
        tokensGenerated: Int? = nil,
        cumulativeTokensPerSecond: Double? = nil,
        gpuPowerWatts: Double? = nil,
        cpuPowerWatts: Double? = nil,
        dramPowerWatts: Double? = nil,
        systemPowerWatts: Double? = nil,
        gpuFrequencyMHz: Double? = nil,
        backendProcessMemoryBytes: Int64? = nil,
        backendProcessCPUPercent: Double? = nil,
        wattsPerToken: Double? = nil
    ) {
        self.id = nil
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.gpuUtilization = gpuUtilization
        self.cpuUtilization = cpuUtilization
        self.anePowerWatts = anePowerWatts
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.thermalState = thermalState
        self.tokensGenerated = tokensGenerated
        self.cumulativeTokensPerSecond = cumulativeTokensPerSecond
        self.gpuPowerWatts = gpuPowerWatts
        self.cpuPowerWatts = cpuPowerWatts
        self.dramPowerWatts = dramPowerWatts
        self.systemPowerWatts = systemPowerWatts
        self.gpuFrequencyMHz = gpuFrequencyMHz
        self.backendProcessMemoryBytes = backendProcessMemoryBytes
        self.backendProcessCPUPercent = backendProcessCPUPercent
        self.wattsPerToken = wattsPerToken
    }

    // MARK: - MutablePersistableRecord

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Database Operations

extension BenchmarkSample {
    /// Fetch all samples for a session
    static func fetchForSession(db: Database, sessionId: Int64) throws -> [BenchmarkSample] {
        try BenchmarkSample
            .filter(CodingKeys.sessionId == sessionId)
            .order(CodingKeys.timestamp.asc)
            .fetchAll(db)
    }

    /// Fetch samples in a time range
    static func fetchInRange(
        db: Database,
        sessionId: Int64,
        from: Date,
        to: Date
    ) throws -> [BenchmarkSample] {
        try BenchmarkSample
            .filter(CodingKeys.sessionId == sessionId)
            .filter(CodingKeys.timestamp >= from && CodingKeys.timestamp <= to)
            .order(CodingKeys.timestamp.asc)
            .fetchAll(db)
    }

    /// Delete samples for a session
    static func deleteForSession(db: Database, sessionId: Int64) throws {
        try BenchmarkSample
            .filter(CodingKeys.sessionId == sessionId)
            .deleteAll(db)
    }

    /// Get statistics for a session
    static func statistics(db: Database, sessionId: Int64) throws -> SampleStatistics? {
        let samples = try fetchForSession(db: db, sessionId: sessionId)
        guard !samples.isEmpty else { return nil }

        let gpuValues = samples.compactMap { $0.gpuUtilization }
        let cpuValues = samples.compactMap { $0.cpuUtilization }
        let tpsValues = samples.compactMap { $0.cumulativeTokensPerSecond }
        let gpuPowerValues = samples.compactMap { $0.gpuPowerWatts }
        let systemPowerValues = samples.compactMap { $0.systemPowerWatts }
        let freqValues = samples.compactMap { $0.gpuFrequencyMHz }
        let wptValues = samples.compactMap { $0.wattsPerToken }

        return SampleStatistics(
            sampleCount: samples.count,
            avgGpuUtilization: gpuValues.isEmpty ? nil : gpuValues.reduce(0, +) / Double(gpuValues.count),
            maxGpuUtilization: gpuValues.max(),
            avgCpuUtilization: cpuValues.isEmpty ? nil : cpuValues.reduce(0, +) / Double(cpuValues.count),
            maxCpuUtilization: cpuValues.max(),
            avgTokensPerSecond: tpsValues.isEmpty ? nil : tpsValues.reduce(0, +) / Double(tpsValues.count),
            peakTokensPerSecond: tpsValues.max(),
            avgGpuPowerWatts: gpuPowerValues.isEmpty ? nil : gpuPowerValues.reduce(0, +) / Double(gpuPowerValues.count),
            peakGpuPowerWatts: gpuPowerValues.max(),
            avgSystemPowerWatts: systemPowerValues.isEmpty ? nil : systemPowerValues.reduce(0, +) / Double(systemPowerValues.count),
            peakSystemPowerWatts: systemPowerValues.max(),
            avgGpuFrequencyMHz: freqValues.isEmpty ? nil : freqValues.reduce(0, +) / Double(freqValues.count),
            peakGpuFrequencyMHz: freqValues.max(),
            avgWattsPerToken: wptValues.isEmpty ? nil : wptValues.reduce(0, +) / Double(wptValues.count)
        )
    }

    /// Compute a PowerSummary from an array of samples (shared by Benchmark + Arena)
    static func computePowerSummary(from samples: [BenchmarkSample]) -> PowerSummary {
        let gpuPower = samples.compactMap { $0.gpuPowerWatts }
        let systemPower = samples.compactMap { $0.systemPowerWatts }
        let freq = samples.compactMap { $0.gpuFrequencyMHz }
        let wpt = samples.compactMap { $0.wattsPerToken }

        return PowerSummary(
            avgGpuPowerWatts: gpuPower.isEmpty ? nil : gpuPower.reduce(0, +) / Double(gpuPower.count),
            peakGpuPowerWatts: gpuPower.max(),
            avgSystemPowerWatts: systemPower.isEmpty ? nil : systemPower.reduce(0, +) / Double(systemPower.count),
            peakSystemPowerWatts: systemPower.max(),
            avgGpuFrequencyMHz: freq.isEmpty ? nil : freq.reduce(0, +) / Double(freq.count),
            peakGpuFrequencyMHz: freq.max(),
            avgWattsPerToken: wpt.isEmpty ? nil : wpt.reduce(0, +) / Double(wpt.count)
        )
    }
}

// MARK: - Statistics

/// Aggregated statistics from benchmark samples
struct SampleStatistics {
    let sampleCount: Int
    let avgGpuUtilization: Double?
    let maxGpuUtilization: Double?
    let avgCpuUtilization: Double?
    let maxCpuUtilization: Double?
    let avgTokensPerSecond: Double?
    let peakTokensPerSecond: Double?
    // v4 power aggregates
    let avgGpuPowerWatts: Double?
    let peakGpuPowerWatts: Double?
    let avgSystemPowerWatts: Double?
    let peakSystemPowerWatts: Double?
    let avgGpuFrequencyMHz: Double?
    let peakGpuFrequencyMHz: Double?
    let avgWattsPerToken: Double?
}

/// Power summary computed from samples (used by BenchmarkSession.complete)
struct PowerSummary {
    let avgGpuPowerWatts: Double?
    let peakGpuPowerWatts: Double?
    let avgSystemPowerWatts: Double?
    let peakSystemPowerWatts: Double?
    let avgGpuFrequencyMHz: Double?
    let peakGpuFrequencyMHz: Double?
    let avgWattsPerToken: Double?
}

// MARK: - Chart Data

extension BenchmarkSample {
    /// Convert samples to chart-friendly data points
    static func chartData(from samples: [BenchmarkSample]) -> BenchmarkChartData {
        var gpuPoints: [(Date, Double)] = []
        var cpuPoints: [(Date, Double)] = []
        var memoryPoints: [(Date, Double)] = []
        var tpsPoints: [(Date, Double)] = []
        var gpuPowerPoints: [(Date, Double)] = []
        var cpuPowerPoints: [(Date, Double)] = []
        var anePowerPoints: [(Date, Double)] = []
        var systemPowerPoints: [(Date, Double)] = []
        var gpuFreqPoints: [(Date, Double)] = []
        var wptPoints: [(Date, Double)] = []
        var backendCPUPoints: [(Date, Double)] = []

        for sample in samples {
            if let gpu = sample.gpuUtilization {
                gpuPoints.append((sample.timestamp, gpu * 100))
            }
            if let cpu = sample.cpuUtilization {
                cpuPoints.append((sample.timestamp, cpu * 100))
            }
            if let memUsed = sample.memoryUsedBytes {
                let memGB = Double(memUsed) / 1_000_000_000.0
                memoryPoints.append((sample.timestamp, memGB))
            }
            if let tps = sample.cumulativeTokensPerSecond {
                tpsPoints.append((sample.timestamp, tps))
            }
            if let gp = sample.gpuPowerWatts, gp > 0 {
                gpuPowerPoints.append((sample.timestamp, gp))
            }
            if let cp = sample.cpuPowerWatts, cp > 0 {
                cpuPowerPoints.append((sample.timestamp, cp))
            }
            if let ap = sample.anePowerWatts, ap > 0 {
                anePowerPoints.append((sample.timestamp, ap))
            }
            if let sp = sample.systemPowerWatts, sp > 0 {
                systemPowerPoints.append((sample.timestamp, sp))
            }
            if let f = sample.gpuFrequencyMHz, f > 0 {
                gpuFreqPoints.append((sample.timestamp, f))
            }
            if let w = sample.wattsPerToken, w > 0 {
                wptPoints.append((sample.timestamp, w))
            }
            if let bc = sample.backendProcessCPUPercent, bc > 0 {
                backendCPUPoints.append((sample.timestamp, bc))
            }
        }

        return BenchmarkChartData(
            gpuUtilization: gpuPoints,
            cpuUtilization: cpuPoints,
            memoryUtilization: memoryPoints,
            tokensPerSecond: tpsPoints,
            gpuPower: gpuPowerPoints,
            cpuPower: cpuPowerPoints,
            anePower: anePowerPoints,
            systemPower: systemPowerPoints,
            gpuFrequency: gpuFreqPoints,
            wattsPerToken: wptPoints,
            backendProcessCPU: backendCPUPoints
        )
    }
}

/// Chart-ready data from benchmark samples
struct BenchmarkChartData {
    let gpuUtilization: [(Date, Double)]
    let cpuUtilization: [(Date, Double)]
    let memoryUtilization: [(Date, Double)]
    let tokensPerSecond: [(Date, Double)]
    // v4 power/frequency series
    let gpuPower: [(Date, Double)]
    let cpuPower: [(Date, Double)]
    let anePower: [(Date, Double)]
    let systemPower: [(Date, Double)]
    let gpuFrequency: [(Date, Double)]
    let wattsPerToken: [(Date, Double)]
    let backendProcessCPU: [(Date, Double)]

    var isEmpty: Bool {
        gpuUtilization.isEmpty && cpuUtilization.isEmpty &&
        memoryUtilization.isEmpty && tokensPerSecond.isEmpty
    }

    var hasPowerData: Bool {
        !gpuPower.isEmpty || !systemPower.isEmpty
    }

    static let empty = BenchmarkChartData(
        gpuUtilization: [], cpuUtilization: [], memoryUtilization: [],
        tokensPerSecond: [], gpuPower: [], cpuPower: [], anePower: [],
        systemPower: [], gpuFrequency: [], wattsPerToken: [], backendProcessCPU: []
    )
}
