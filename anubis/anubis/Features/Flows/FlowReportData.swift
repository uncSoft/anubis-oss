//
//  FlowReportData.swift
//  anubis
//
//  Pure-Swift aggregator that turns a FlowRun + its child sessions
//  into the data structure the report view renders. Doing the math
//  outside the SwiftUI body keeps the view fast and lets us reuse
//  the same numbers when exporting CSV / JSON.
//
//  Sessions are grouped by `modelName + backend`, ranked by mean
//  tokens-per-second descending. Failed and cancelled sessions are
//  excluded from the math (they would skew the distribution) but
//  still counted in `attemptCount` so a report honestly shows that
//  one of the runs flaked.
//

import Foundation

struct FlowReportData: Identifiable {
    /// Identity is the underlying FlowRun row id when present, else a
    /// random UUID so SwiftUI's .sheet(item:) still functions before
    /// the row is persisted.
    var id: String {
        flowRun.id.map { "flowrun-\($0)" } ?? "flowrun-temp-\(UUID().uuidString)"
    }

    /// One row per (model, backend) pair, ranked best-first by tok/s.
    struct PerModelRow: Identifiable, Hashable {
        let id = UUID()
        let rank: Int
        let modelName: String
        let backend: String
        /// Successful sessions only (used for the math).
        let completedSessions: [BenchmarkSession]
        /// Total attempts including failures/cancellations.
        let attemptCount: Int
        let n: Int                       // == completedSessions.count
        let meanTPS: Double
        let stdevTPS: Double
        let ciLowTPS: Double?
        let ciHighTPS: Double?
        let meanTTFT: Double?            // seconds
        let meanTotalTokens: Double?     // tokens
        let meanTotalDuration: Double?   // seconds
    }

    let flowRun: FlowRun
    let allSessions: [BenchmarkSession]
    let chipInfo: ChipInfo?
    let modelRows: [PerModelRow]

    /// Wall-clock duration of the flow execution, or nil if still running.
    var duration: TimeInterval? {
        guard let end = flowRun.endedAt else { return nil }
        return end.timeIntervalSince(flowRun.startedAt)
    }

    /// Sum of completed sessions across all model rows. Distinct from
    /// `allSessions.count` because failed/cancelled rows are excluded.
    var completedSessionCount: Int {
        modelRows.reduce(0) { $0 + $1.n }
    }

    var failedSessionCount: Int {
        allSessions.filter { $0.status == .failed }.count
    }

    /// Best (rank 1) model by mean tok/s, if any.
    var winner: PerModelRow? { modelRows.first }

    /// True if every model row has only one completed session — the CI
    /// columns aren't meaningful in that case, and the report should
    /// suppress them.
    var hasMultipleReps: Bool {
        modelRows.contains { $0.n > 1 }
    }

    // MARK: - Compute

    static func compute(flowRun: FlowRun, sessions: [BenchmarkSession]) -> FlowReportData {
        let completed = sessions.filter { $0.status == .completed }

        // Group by (modelName, backend) — same model on Ollama vs
        // OpenAI counts as two rows, which is what a viewer comparing
        // backends would expect.
        struct Key: Hashable { let modelName: String; let backend: String }
        let grouped = Dictionary(grouping: completed) {
            Key(modelName: $0.modelName, backend: $0.backend)
        }
        let attemptsByKey = Dictionary(grouping: sessions) {
            Key(modelName: $0.modelName, backend: $0.backend)
        }.mapValues { $0.count }

        var rows: [PerModelRow] = []
        for (key, modelSessions) in grouped {
            let tps = modelSessions.compactMap { $0.tokensPerSecond }
            let ttft = modelSessions.compactMap { $0.timeToFirstToken }
            let tokens = modelSessions.compactMap { $0.totalTokens.map(Double.init) }
            let duration = modelSessions.compactMap { $0.totalDuration }

            let ci = tps.count > 1 ? BootstrapCI.confidenceInterval95(tps) : nil

            rows.append(PerModelRow(
                rank: 0,  // assigned post-sort
                modelName: key.modelName,
                backend: key.backend,
                completedSessions: modelSessions,
                attemptCount: attemptsByKey[key] ?? modelSessions.count,
                n: modelSessions.count,
                meanTPS: BootstrapCI.mean(tps) ?? 0,
                stdevTPS: BootstrapCI.stdev(tps) ?? 0,
                ciLowTPS: ci?.low,
                ciHighTPS: ci?.high,
                meanTTFT: BootstrapCI.mean(ttft),
                meanTotalTokens: BootstrapCI.mean(tokens),
                meanTotalDuration: BootstrapCI.mean(duration)
            ))
        }

        // Sort by mean TPS desc, then by name for stable ordering when
        // two models tie (e.g. trivial prompts).
        rows.sort { ($0.meanTPS, $1.modelName) > ($1.meanTPS, $0.modelName) }

        // Assign ranks.
        rows = rows.enumerated().map { idx, row in
            PerModelRow(
                rank: idx + 1,
                modelName: row.modelName,
                backend: row.backend,
                completedSessions: row.completedSessions,
                attemptCount: row.attemptCount,
                n: row.n,
                meanTPS: row.meanTPS,
                stdevTPS: row.stdevTPS,
                ciLowTPS: row.ciLowTPS,
                ciHighTPS: row.ciHighTPS,
                meanTTFT: row.meanTTFT,
                meanTotalTokens: row.meanTotalTokens,
                meanTotalDuration: row.meanTotalDuration
            )
        }

        // Pull chip info from the first session that has it
        // (deterministic and always populated for current builds).
        let chip: ChipInfo? = {
            for s in sessions {
                if let json = s.chipInfoJSON,
                   let data = json.data(using: .utf8),
                   let info = try? JSONDecoder().decode(ChipInfo.self, from: data) {
                    return info
                }
            }
            return nil
        }()

        return FlowReportData(
            flowRun: flowRun,
            allSessions: sessions,
            chipInfo: chip,
            modelRows: rows
        )
    }
}

// MARK: - CSV export helpers

extension FlowReportData {
    /// One row per (model, backend), columns matched to the on-screen
    /// metrics. Quote-escaped for CSV; null cells become empty strings.
    func toCSV() -> String {
        let header = [
            "rank", "model", "backend", "n_completed", "n_attempted",
            "mean_tokens_per_second", "stdev_tokens_per_second",
            "ci_low_tokens_per_second", "ci_high_tokens_per_second",
            "mean_ttft_ms", "mean_total_tokens", "mean_total_duration_s"
        ].joined(separator: ",")

        var lines = [header]
        for row in modelRows {
            let cells: [String] = [
                "\(row.rank)",
                csvEscape(row.modelName),
                csvEscape(row.backend),
                "\(row.n)",
                "\(row.attemptCount)",
                csvNum(row.meanTPS, fmt: "%.3f"),
                csvNum(row.stdevTPS, fmt: "%.3f"),
                csvNum(row.ciLowTPS, fmt: "%.3f"),
                csvNum(row.ciHighTPS, fmt: "%.3f"),
                csvNum(row.meanTTFT.map { $0 * 1000 }, fmt: "%.1f"),
                csvNum(row.meanTotalTokens, fmt: "%.1f"),
                csvNum(row.meanTotalDuration, fmt: "%.3f"),
            ]
            lines.append(cells.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private func csvNum(_ value: Double?, fmt: String) -> String {
        guard let v = value else { return "" }
        return String(format: fmt, v)
    }

    private func csvNum(_ value: Double, fmt: String) -> String {
        String(format: fmt, value)
    }
}
