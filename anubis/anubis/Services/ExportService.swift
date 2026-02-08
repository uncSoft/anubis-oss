//
//  ExportService.swift
//  anubis
//
//  Created on 2026-01-26.
//

import Foundation
import UniformTypeIdentifiers

/// Service for exporting benchmark data to various formats
enum ExportService {

    // MARK: - CSV Export

    /// Export benchmark sessions to CSV
    static func exportSessionsToCSV(_ sessions: [BenchmarkSession]) -> String {
        var csv = "id,model_id,model_name,backend,started_at,ended_at,status,"
        csv += "tokens_per_second,total_tokens,prompt_tokens,completion_tokens,"
        csv += "time_to_first_token_sec,avg_token_latency_ms,load_duration_sec,"
        csv += "context_length,peak_memory_bytes,total_duration_sec,eval_duration_sec,"
        csv += "prompt_eval_duration_sec,"
        csv += "avg_gpu_power_watts,peak_gpu_power_watts,avg_system_power_watts,peak_system_power_watts,"
        csv += "avg_gpu_frequency_mhz,peak_gpu_frequency_mhz,avg_watts_per_token,"
        csv += "backend_process_name,chip_info,"
        csv += "prompt\n"

        let dateFormatter = ISO8601DateFormatter()

        for session in sessions {
            var row: [String] = []
            row.append(session.id.map { "\($0)" } ?? "")
            row.append(escapeCSV(session.modelId))
            row.append(escapeCSV(session.modelName))
            row.append(escapeCSV(session.backend))
            row.append(dateFormatter.string(from: session.startedAt))
            row.append(session.endedAt.map { dateFormatter.string(from: $0) } ?? "")
            row.append(session.status.rawValue)
            row.append(session.tokensPerSecond.map { String(format: "%.2f", $0) } ?? "")
            row.append(session.totalTokens.map { "\($0)" } ?? "")
            row.append(session.promptTokens.map { "\($0)" } ?? "")
            row.append(session.completionTokens.map { "\($0)" } ?? "")
            row.append(session.timeToFirstToken.map { String(format: "%.4f", $0) } ?? "")
            row.append(session.averageTokenLatencyMs.map { String(format: "%.2f", $0) } ?? "")
            row.append(session.loadDuration.map { String(format: "%.4f", $0) } ?? "")
            row.append(session.contextLength.map { "\($0)" } ?? "")
            row.append(session.peakMemoryBytes.map { "\($0)" } ?? "")
            row.append(session.totalDuration.map { String(format: "%.4f", $0) } ?? "")
            row.append(session.evalDuration.map { String(format: "%.4f", $0) } ?? "")
            row.append(session.promptEvalDuration.map { String(format: "%.4f", $0) } ?? "")
            // v4 power/frequency
            row.append(session.avgGpuPowerWatts.map { String(format: "%.2f", $0) } ?? "")
            row.append(session.peakGpuPowerWatts.map { String(format: "%.2f", $0) } ?? "")
            row.append(session.avgSystemPowerWatts.map { String(format: "%.2f", $0) } ?? "")
            row.append(session.peakSystemPowerWatts.map { String(format: "%.2f", $0) } ?? "")
            row.append(session.avgGpuFrequencyMHz.map { String(format: "%.0f", $0) } ?? "")
            row.append(session.peakGpuFrequencyMHz.map { String(format: "%.0f", $0) } ?? "")
            row.append(session.avgWattsPerToken.map { String(format: "%.4f", $0) } ?? "")
            row.append(escapeCSV(session.backendProcessName ?? ""))
            row.append(escapeCSV(session.chipInfo?.summary ?? ""))
            row.append(escapeCSV(session.prompt))

            csv += row.joined(separator: ",") + "\n"
        }

        return csv
    }

    /// Export benchmark samples to CSV
    static func exportSamplesToCSV(_ samples: [BenchmarkSample], sessionId: Int64? = nil) -> String {
        var csv = "id,session_id,timestamp,gpu_utilization,cpu_utilization,"
        csv += "ane_power_watts,memory_used_bytes,memory_total_bytes,"
        csv += "thermal_state,tokens_generated,tokens_per_second,"
        csv += "gpu_power_watts,cpu_power_watts,dram_power_watts,system_power_watts,"
        csv += "gpu_frequency_mhz,backend_process_memory_bytes,backend_process_cpu_percent,"
        csv += "watts_per_token\n"

        let dateFormatter = ISO8601DateFormatter()

        for sample in samples {
            var row: [String] = []
            row.append(sample.id.map { "\($0)" } ?? "")
            row.append("\(sample.sessionId)")
            row.append(dateFormatter.string(from: sample.timestamp))
            row.append(sample.gpuUtilization.map { String(format: "%.4f", $0) } ?? "")
            row.append(sample.cpuUtilization.map { String(format: "%.4f", $0) } ?? "")
            row.append(sample.anePowerWatts.map { String(format: "%.2f", $0) } ?? "")
            row.append(sample.memoryUsedBytes.map { "\($0)" } ?? "")
            row.append(sample.memoryTotalBytes.map { "\($0)" } ?? "")
            row.append(sample.thermalState.map { "\($0)" } ?? "")
            row.append(sample.tokensGenerated.map { "\($0)" } ?? "")
            row.append(sample.cumulativeTokensPerSecond.map { String(format: "%.2f", $0) } ?? "")
            // v4 power/frequency
            row.append(sample.gpuPowerWatts.map { String(format: "%.2f", $0) } ?? "")
            row.append(sample.cpuPowerWatts.map { String(format: "%.2f", $0) } ?? "")
            row.append(sample.dramPowerWatts.map { String(format: "%.2f", $0) } ?? "")
            row.append(sample.systemPowerWatts.map { String(format: "%.2f", $0) } ?? "")
            row.append(sample.gpuFrequencyMHz.map { String(format: "%.0f", $0) } ?? "")
            row.append(sample.backendProcessMemoryBytes.map { "\($0)" } ?? "")
            row.append(sample.backendProcessCPUPercent.map { String(format: "%.1f", $0) } ?? "")
            row.append(sample.wattsPerToken.map { String(format: "%.4f", $0) } ?? "")

            csv += row.joined(separator: ",") + "\n"
        }

        return csv
    }

    /// Export a single session with its samples as a combined report
    static func exportSessionReport(_ session: BenchmarkSession, samples: [BenchmarkSample]) -> String {
        var report = "# Benchmark Session Report\n\n"

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium

        // Session summary
        report += "## Session Summary\n\n"
        report += "Model: \(session.modelName)\n"
        report += "Backend: \(session.backend)\n"
        report += "Status: \(session.status.rawValue)\n"
        report += "Started: \(dateFormatter.string(from: session.startedAt))\n"
        if let ended = session.endedAt {
            report += "Ended: \(dateFormatter.string(from: ended))\n"
        }
        report += "\n"

        // Performance metrics
        report += "## Performance Metrics\n\n"
        if let tps = session.tokensPerSecond {
            report += "Tokens/sec: \(String(format: "%.2f", tps))\n"
        }
        if let ttft = session.timeToFirstToken {
            report += "Time to First Token: \(String(format: "%.0f", ttft * 1000))ms\n"
        }
        if let latency = session.averageTokenLatencyMs {
            report += "Avg Token Latency: \(String(format: "%.2f", latency))ms\n"
        }
        if let load = session.loadDuration {
            report += "Model Load Time: \(String(format: "%.2f", load))s\n"
        }
        report += "\n"

        // Token counts
        report += "## Token Counts\n\n"
        if let total = session.totalTokens {
            report += "Total Tokens: \(total)\n"
        }
        if let prompt = session.promptTokens {
            report += "Prompt Tokens: \(prompt)\n"
        }
        if let completion = session.completionTokens {
            report += "Completion Tokens: \(completion)\n"
        }
        if let context = session.contextLength {
            report += "Context Length: \(context)\n"
        }
        report += "\n"

        // Power & Efficiency
        let hasPower = session.avgGpuPowerWatts != nil || session.avgSystemPowerWatts != nil
        if hasPower {
            report += "## Power & Efficiency\n\n"
            if let v = session.avgGpuPowerWatts {
                report += "Avg GPU Power: \(String(format: "%.2f", v))W\n"
            }
            if let v = session.peakGpuPowerWatts {
                report += "Peak GPU Power: \(String(format: "%.2f", v))W\n"
            }
            if let v = session.avgSystemPowerWatts {
                report += "Avg System Power: \(String(format: "%.2f", v))W\n"
            }
            if let v = session.peakSystemPowerWatts {
                report += "Peak System Power: \(String(format: "%.2f", v))W\n"
            }
            if let v = session.avgWattsPerToken {
                report += "Avg Watts/Token: \(String(format: "%.4f", v)) W/tok\n"
            }
            if let v = session.avgGpuFrequencyMHz {
                report += "Avg GPU Frequency: \(String(format: "%.0f", v)) MHz\n"
            }
            if let v = session.peakGpuFrequencyMHz {
                report += "Peak GPU Frequency: \(String(format: "%.0f", v)) MHz\n"
            }
            report += "\n"
        }

        // Hardware
        report += "## Hardware\n\n"
        if let chip = session.chipInfo {
            report += "Chip: \(chip.summary)\n"
        }
        if let backend = session.backendProcessName {
            report += "Backend Process: \(backend)\n"
        }
        if let mem = session.peakMemoryBytes {
            report += "Peak Memory: \(Formatters.bytes(mem))\n"
        }
        report += "\n"

        // Prompt
        report += "## Prompt\n\n"
        report += session.prompt + "\n\n"

        // Response
        if let response = session.response {
            report += "## Response\n\n"
            report += response + "\n\n"
        }

        // Samples CSV
        if !samples.isEmpty {
            report += "## Time Series Data (CSV)\n\n"
            report += exportSamplesToCSV(samples)
        }

        return report
    }

    // MARK: - Helpers

    private static func escapeCSV(_ string: String) -> String {
        let needsQuoting = string.contains(",") || string.contains("\"") || string.contains("\n")
        if needsQuoting {
            let escaped = string.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return string
    }
}

// MARK: - File Export

extension ExportService {
    /// Save CSV to a file and return the URL
    static func saveToFile(_ content: String, filename: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(filename)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
