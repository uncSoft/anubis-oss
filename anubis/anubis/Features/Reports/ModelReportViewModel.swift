//
//  ModelReportViewModel.swift
//  anubis
//
//  Created on 2026-03-18.
//

import Foundation
import Combine
@preconcurrency import GRDB

/// Aggregated stats for a distinct model configuration
struct ModelReportRow: Identifiable {
    let id: String  // modelName + quantization + format
    let modelName: String
    let quantization: String?
    let format: String?
    let backend: String
    let avgTokensPerSecond: Double
    let avgWattsPerToken: Double?
    let avgTimeToFirstToken: Double?
    let avgTokenLatencyMs: Double?
    let avgSystemPowerWatts: Double?
    let peakMemoryBytes: Int64?
    let runCount: Int
}

/// Sortable columns for the report table
enum ReportSortColumn: String, CaseIterable {
    case modelName = "Model"
    case avgTokensPerSecond = "Avg Tk/s"
    case avgWattsPerToken = "Avg W/Tk"
    case avgTimeToFirstToken = "TTFT"
    case avgSystemPowerWatts = "Avg Power"
    case peakMemoryBytes = "Peak Mem"
    case runCount = "Runs"
}

@MainActor
final class ModelReportViewModel: ObservableObject {
    private let databaseManager: DatabaseManager

    @Published var allModels: [ModelReportRow] = []
    @Published var selectedModelIds: Set<String> = []
    @Published var sortColumn: ReportSortColumn = .avgTokensPerSecond
    @Published var sortAscending: Bool = false
    @Published var isLoading = false

    var selectedModels: [ModelReportRow] {
        let filtered = selectedModelIds.isEmpty ? allModels : allModels.filter { selectedModelIds.contains($0.id) }
        return sorted(filtered)
    }

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
    }

    func loadModels() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let rows = try await databaseManager.queue.read { db -> [ModelReportRow] in
                // Group by model_name only — backend names are user-defined and
                // fragment the same model across entries. Pick the most common
                // non-null quant/format/backend for display via subqueries.
                let sql = """
                    SELECT
                        s.model_name,
                        AVG(s.tokens_per_second) AS avg_tps,
                        AVG(s.avg_watts_per_token) AS avg_wpt,
                        AVG(s.time_to_first_token) AS avg_ttft,
                        AVG(s.avg_token_latency_ms) AS avg_latency,
                        AVG(s.avg_system_power_watts) AS avg_power,
                        MAX(s.peak_memory_bytes) AS peak_mem,
                        COUNT(*) AS run_count,
                        (SELECT q.model_quantization FROM benchmark_session q
                         WHERE q.model_name = s.model_name
                           AND q.model_quantization IS NOT NULL
                         GROUP BY q.model_quantization ORDER BY COUNT(*) DESC LIMIT 1) AS best_quant,
                        (SELECT f.model_format FROM benchmark_session f
                         WHERE f.model_name = s.model_name
                           AND f.model_format IS NOT NULL
                         GROUP BY f.model_format ORDER BY COUNT(*) DESC LIMIT 1) AS best_format,
                        (SELECT b.backend FROM benchmark_session b
                         WHERE b.model_name = s.model_name
                         GROUP BY b.backend ORDER BY COUNT(*) DESC LIMIT 1) AS best_backend
                    FROM benchmark_session s
                    WHERE s.status = 'completed'
                        AND s.tokens_per_second IS NOT NULL
                        AND s.tokens_per_second > 0
                    GROUP BY s.model_name
                    ORDER BY s.model_name COLLATE NOCASE ASC
                    """

                var results: [ModelReportRow] = []
                let rows = try Row.fetchAll(db, sql: sql)
                for row in rows {
                    let modelName: String = row["model_name"]
                    let quant: String? = row["best_quant"]
                    let format: String? = row["best_format"]
                    let backend: String = row["best_backend"] ?? ""

                    results.append(ModelReportRow(
                        id: modelName,
                        modelName: modelName,
                        quantization: quant,
                        format: format,
                        backend: backend,
                        avgTokensPerSecond: row["avg_tps"] ?? 0,
                        avgWattsPerToken: row["avg_wpt"],
                        avgTimeToFirstToken: row["avg_ttft"],
                        avgTokenLatencyMs: row["avg_latency"],
                        avgSystemPowerWatts: row["avg_power"],
                        peakMemoryBytes: row["peak_mem"],
                        runCount: row["run_count"] ?? 0
                    ))
                }
                return results
            }

            allModels = rows
        } catch {
            print("Failed to load model report: \(error)")
        }
    }

    func toggleSelection(_ id: String) {
        if selectedModelIds.contains(id) {
            selectedModelIds.remove(id)
        } else {
            selectedModelIds.insert(id)
        }
    }

    func selectAll() {
        selectedModelIds = Set(allModels.map(\.id))
    }

    func clearSelection() {
        selectedModelIds.removeAll()
    }

    func toggleSort(_ column: ReportSortColumn) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = column == .modelName // alpha ascending by default for name
        }
    }

    private func sorted(_ rows: [ModelReportRow]) -> [ModelReportRow] {
        rows.sorted { a, b in
            let result: Bool
            switch sortColumn {
            case .modelName:
                result = a.modelName.localizedCaseInsensitiveCompare(b.modelName) == .orderedAscending
            case .avgTokensPerSecond:
                result = a.avgTokensPerSecond < b.avgTokensPerSecond
            case .avgWattsPerToken:
                result = (a.avgWattsPerToken ?? .infinity) < (b.avgWattsPerToken ?? .infinity)
            case .avgTimeToFirstToken:
                result = (a.avgTimeToFirstToken ?? .infinity) < (b.avgTimeToFirstToken ?? .infinity)
            case .avgSystemPowerWatts:
                result = (a.avgSystemPowerWatts ?? .infinity) < (b.avgSystemPowerWatts ?? .infinity)
            case .peakMemoryBytes:
                result = (a.peakMemoryBytes ?? Int64.max) < (b.peakMemoryBytes ?? Int64.max)
            case .runCount:
                result = a.runCount < b.runCount
            }
            return sortAscending ? result : !result
        }
    }
}
