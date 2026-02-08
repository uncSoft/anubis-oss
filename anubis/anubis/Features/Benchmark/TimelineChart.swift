//
//  TimelineChart.swift
//  anubis
//
//  Created on 2026-01-25.
//

import SwiftUI
import Charts

/// Real-time line chart for benchmark metrics
struct TimelineChart: View {
    let title: String
    let data: [(Date, Double)]
    let color: Color
    let unit: String
    var maxValue: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if !data.isEmpty {
                    let avg = data.map(\.1).reduce(0, +) / Double(data.count)
                    Text(formatValue(avg))
                        .font(.mono(14, weight: .medium))
                        .foregroundStyle(color)
                }
            }

            if data.isEmpty {
                emptyState
            } else {
                chart
            }
        }
        .cardStyle()
    }

    private var emptyState: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .fill(Color.emptyStateBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .strokeBorder(Color.cardBorder, lineWidth: 1)
                }
            VStack(spacing: Spacing.xs) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.title2)
                    .foregroundStyle(.quaternary)
                Text("No data")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 120)
    }

    private var chart: some View {
        Chart(data, id: \.0) { point in
            AreaMark(
                x: .value("Time", point.0),
                yStart: .value("Baseline", 0),
                yEnd: .value(title, point.1)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [color.opacity(0.02), color.opacity(0.2)],
                    startPoint: .bottom,
                    endPoint: .top
                )
            )
            .interpolationMethod(.linear)

            LineMark(
                x: .value("Time", point.0),
                y: .value(title, point.1)
            )
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
            .interpolationMethod(.linear)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.minute().second())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(formatValue(v))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartYScale(domain: yDomain)
        .frame(height: 120)
        .clipped()
    }

    private var yDomain: ClosedRange<Double> {
        if let max = maxValue {
            return 0...(max * 1.08) // Small headroom so top label isn't clipped
        }
        let values = data.map { $0.1 }
        let max = values.max() ?? 100
        return 0...(max * 1.1) // 10% headroom
    }

    /// Auto-select power unit prefix based on max data value
    private enum PowerScale { case watts, milliwatts, microwatts }
    private var powerScale: PowerScale {
        guard unit == "W" else { return .watts }
        let maxVal = data.map(\.1).max() ?? 0
        if maxVal >= 1.0 { return .watts }
        if maxVal >= 0.001 { return .milliwatts }
        return .microwatts
    }

    private func formatValue(_ value: Double) -> String {
        if unit == "%" {
            return String(format: "%.0f%%", value)
        } else if unit == "W" {
            switch powerScale {
            case .watts:
                return String(format: "%.1fW", value)
            case .milliwatts:
                let mw = value * 1_000
                return mw >= 10 ? String(format: "%.0f mW", mw) : String(format: "%.1f mW", mw)
            case .microwatts:
                let uw = value * 1_000_000
                return uw >= 10 ? String(format: "%.0f \u{00B5}W", uw) : String(format: "%.1f \u{00B5}W", uw)
            }
        } else {
            return String(format: "%.1f \(unit)", value)
        }
    }
}

/// Timeline chart for memory with GB display
struct MemoryTimelineChart: View {
    let title: String
    let data: [(Date, Double)]  // Values in GB
    let currentBytes: Int64     // Current memory in bytes for header display
    let totalBytes: Int64       // Total system memory for percentage calc
    let color: Color

    private var currentPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(currentBytes) / Double(totalBytes) * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()

                // Show both absolute and percentage
                if currentBytes > 0 {
                    HStack(spacing: Spacing.sm) {
                        // Absolute value (primary)
                        Text(Formatters.bytes(currentBytes))
                            .font(.mono(14, weight: .semibold))
                            .foregroundStyle(color)

                        // Percentage of system RAM (secondary)
                        Text("(\(String(format: "%.0f%%", currentPercent)) of RAM)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if data.isEmpty {
                emptyState
            } else {
                chart
            }
        }
        .cardStyle()
    }

    private var emptyState: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .fill(Color.emptyStateBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .strokeBorder(Color.cardBorder, lineWidth: 1)
                }
            VStack(spacing: Spacing.xs) {
                Image(systemName: "memorychip")
                    .font(.title2)
                    .foregroundStyle(.quaternary)
                Text("Waiting for data...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 150)
    }

    private var chart: some View {
        Chart(data, id: \.0) { point in
            AreaMark(
                x: .value("Time", point.0),
                yStart: .value("Baseline", 0),
                yEnd: .value("GB", point.1)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [color.opacity(0.02), color.opacity(0.2)],
                    startPoint: .bottom,
                    endPoint: .top
                )
            )
            .interpolationMethod(.linear)

            LineMark(
                x: .value("Time", point.0),
                y: .value("GB", point.1)
            )
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
            .interpolationMethod(.linear)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.minute().second())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(String(format: "%.1f GB", v))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartYScale(domain: yDomain)
        .frame(height: 150)
        .clipped()
    }

    private var yDomain: ClosedRange<Double> {
        let values = data.map { $0.1 }
        let maxVal = values.max() ?? 0
        // Round up to nearest whole GB, minimum 1 GB, with 8% headroom for top label
        let ceiling = max(ceil(maxVal + 0.1), 1)
        return 0...(ceiling * 1.08)
    }
}

/// Multi-series chart for comparing metrics
struct MultiSeriesChart: View {
    let title: String
    let series: [(name: String, data: [(Date, Double)], color: Color)]
    var unit: String = "%"

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                ForEach(series, id: \.name) { item in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(item.color)
                            .frame(width: 8, height: 8)
                        Text(item.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Chart {
                ForEach(series, id: \.name) { item in
                    ForEach(item.data, id: \.0) { point in
                        LineMark(
                            x: .value("Time", point.0),
                            y: .value("Value", point.1),
                            series: .value("Series", item.name)
                        )
                        .foregroundStyle(item.color)
                        .interpolationMethod(.monotone)
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.minute().second())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(formatAxisValue(v))
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartYScale(domain: yDomain)
            .frame(height: 150)
            .drawingGroup()
        }
        .cardStyle()
    }

    private var yDomain: ClosedRange<Double> {
        if unit == "%" { return 0...108 }
        let allValues = series.flatMap { $0.data.map { $0.1 } }
        let maxVal = allValues.max() ?? 100
        return 0...(maxVal * 1.1)
    }

    private func formatAxisValue(_ value: Double) -> String {
        if unit == "%" {
            return String(format: "%.0f%%", value)
        } else if unit == "W" {
            return String(format: "%.1fW", value)
        } else {
            return String(format: "%.0f %@", value, unit)
        }
    }
}

#Preview("Timeline Chart") {
    let now = Date()
    let data: [(Date, Double)] = (0..<30).map { i in
        (now.addingTimeInterval(TimeInterval(i) * -0.5), Double.random(in: 20...80))
    }.reversed()

    return VStack(spacing: Spacing.md) {
        TimelineChart(
            title: "Tokens per Second",
            data: data,
            color: .chartTokens,
            unit: "tok/s"
        )

        TimelineChart(
            title: "GPU Utilization",
            data: data,
            color: .chartGPU,
            unit: "%",
            maxValue: 100
        )

        MultiSeriesChart(
            title: "Utilization",
            series: [
                ("GPU", data, .chartGPU),
                ("CPU", data.map { ($0.0, $0.1 * 0.4) }, .chartCPU)
            ]
        )
    }
    .padding()
    .frame(width: 500)
}
