//
//  GPUCoreView.swift
//  anubis
//
//  Created on 2026-02-23.
//

import SwiftUI
import Charts

// MARK: - Inline GPU Core Grid

/// Card-sized view showing a grid of vertical utilization bars for GPU cores.
/// All bars display the same aggregate utilization (Apple Silicon exposes no per-core GPU breakdown).
/// Scales from 8 cores (M1) to 76+ (M4 Ultra) with adaptive layout.
struct GPUCoreGrid: View {
    let gpuUtilization: Double  // 0.0–1.0
    let onExpand: () -> Void

    private var gpuCoreCount: Int { ChipInfo.current.gpuCores }

    private var coreSummary: String {
        "\(gpuCoreCount) cores"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // Header
            HStack {
                Text("GPU Cores")
                    .font(.headline)
                Spacer()
                Text(coreSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    onExpand()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open GPU detail window")
            }

            if gpuCoreCount == 0 {
                emptyState
            } else {
                coreBarGrid
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
                Image(systemName: "gpu")
                    .font(.title2)
                    .foregroundStyle(.quaternary)
                Text("No GPU cores detected")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 150)
    }

    private var coreBarGrid: some View {
        let count = gpuCoreCount
        let showLabels = count <= 24
        let barSpacing: CGFloat = count > 40 ? 1 : count > 20 ? 2 : 3

        return GeometryReader { geo in
            let labelHeight: CGFloat = showLabels ? 14 : 0
            let availableWidth = geo.size.width
            let totalSpacing = CGFloat(max(0, count - 1)) * barSpacing
            let barWidth = (availableWidth - totalSpacing) / CGFloat(count)
            let barAreaHeight = geo.size.height - labelHeight - (showLabels ? 4 : 0)

            if barWidth >= 3 {
                // Single-row HStack layout
                HStack(alignment: .bottom, spacing: barSpacing) {
                    ForEach(0..<count, id: \.self) { index in
                        gpuCoreBar(
                            index: index,
                            width: barWidth,
                            height: barAreaHeight,
                            labelHeight: labelHeight,
                            showLabel: showLabels
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                // Wrapped multi-row layout for very high core counts
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 6))],
                    spacing: 1
                ) {
                    ForEach(0..<count, id: \.self) { _ in
                        gpuCoreMiniBar(height: 20)
                    }
                }
            }
        }
        .frame(height: 150)
    }

    private func gpuCoreBar(index: Int, width: CGFloat, height: CGFloat, labelHeight: CGFloat, showLabel: Bool) -> some View {
        let fillHeight = max(2, height * gpuUtilization)

        return VStack(spacing: 2) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.chartGPUCore.opacity(0.1))
                    .frame(width: width, height: height)

                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.chartGPUCore)
                    .frame(width: width, height: fillHeight)
            }

            if showLabel {
                Text("\(index)")
                    .font(.system(size: 7))
                    .foregroundStyle(.tertiary)
                    .frame(height: labelHeight)
            }
        }
    }

    private func gpuCoreMiniBar(height: CGFloat) -> some View {
        let fillHeight = max(1, height * gpuUtilization)

        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.chartGPUCore.opacity(0.1))
                .frame(height: height)

            RoundedRectangle(cornerRadius: 1)
                .fill(Color.chartGPUCore)
                .frame(height: fillHeight)
        }
    }
}

// MARK: - GPU Detail View (Pop-Out Window)

/// GPU detail window with time-series sparklines and P-state frequency distribution.
struct GPUDetailView: View {
    @ObservedObject var viewModel: BenchmarkViewModel

    private var chip: ChipInfo { ChipInfo.current }

    private var currentUtil: String {
        String(format: "%.0f%%", viewModel.latestGPUUtilization * 100)
    }

    private var currentFreq: String {
        if let freq = viewModel.currentMetrics?.gpuFrequencyMHz, freq > 0 {
            return String(format: "%.0f MHz", freq)
        }
        // Fall back to latest accumulated sample
        if let lastFreq = viewModel.gpuDetailData.frequencyMHz.samples.last?.1, lastFreq > 0 {
            return String(format: "%.0f MHz", lastFreq)
        }
        return "—"
    }

    private var currentPower: String {
        if let power = viewModel.currentMetrics?.gpuPowerWatts, power > 0 {
            return String(format: "%.1f W", power)
        }
        if let lastPower = viewModel.gpuDetailData.powerWatts.samples.last?.1, lastPower > 0 {
            return String(format: "%.1f W", lastPower)
        }
        return "—"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chip.name)
                        .font(.headline)
                    Text("\(chip.gpuCores) GPU cores")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                // Live stats
                HStack(spacing: Spacing.md) {
                    VStack(spacing: 2) {
                        Text("Utilization")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(currentUtil)
                            .font(.mono(14, weight: .semibold))
                            .foregroundStyle(Color.chartGPUCore)
                    }
                    VStack(spacing: 2) {
                        Text("Frequency")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(currentFreq)
                            .font(.mono(14, weight: .semibold))
                            .foregroundStyle(Color.chartFrequency)
                    }
                    VStack(spacing: 2) {
                        Text("Power")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(currentPower)
                            .font(.mono(14, weight: .semibold))
                            .foregroundStyle(Color.chartGPUPower)
                    }
                }

                Button("Done") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(Spacing.md)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    // Section 1: GPU Core grid
                    if chip.gpuCores > 0 {
                        coreGridSection
                    }

                    // Section 2: GPU Metrics sparklines
                    metricsSection

                    // Section 3: P-state frequency distribution
                    if !viewModel.gpuDetailData.latestPStateDistribution.isEmpty {
                        pStateSection
                    }
                }
                .padding(Spacing.md)
            }
        }
    }

    // MARK: - GPU Core Grid

    private var coreGridSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("GPU Cores")
                    .font(.headline)
                Spacer()
                Text(String(format: "%.0f%%", viewModel.latestGPUUtilization * 100))
                    .font(.mono(14, weight: .semibold))
                    .foregroundStyle(Color.chartGPUCore)
            }

            detailCoreBarGrid
        }
    }

    private var detailCoreBarGrid: some View {
        let count = chip.gpuCores
        let showLabels = count <= 32
        let barSpacing: CGFloat = count > 40 ? 1 : count > 20 ? 2 : 3

        return GeometryReader { geo in
            let labelHeight: CGFloat = showLabels ? 14 : 0
            let availableWidth = geo.size.width
            let totalSpacing = CGFloat(max(0, count - 1)) * barSpacing
            let barWidth = (availableWidth - totalSpacing) / CGFloat(count)
            let barAreaHeight = geo.size.height - labelHeight - (showLabels ? 4 : 0)
            let util = viewModel.latestGPUUtilization

            if barWidth >= 3 {
                HStack(alignment: .bottom, spacing: barSpacing) {
                    ForEach(0..<count, id: \.self) { index in
                        detailCoreBar(
                            index: index,
                            utilization: util,
                            width: barWidth,
                            height: barAreaHeight,
                            labelHeight: labelHeight,
                            showLabel: showLabels
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 6))],
                    spacing: 1
                ) {
                    ForEach(0..<count, id: \.self) { _ in
                        detailCoreMiniBar(utilization: util, height: 24)
                    }
                }
            }
        }
        .frame(height: 120)
    }

    private func detailCoreBar(index: Int, utilization: Double, width: CGFloat, height: CGFloat, labelHeight: CGFloat, showLabel: Bool) -> some View {
        let fillHeight = max(2, height * utilization)

        return VStack(spacing: 2) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.chartGPUCore.opacity(0.1))
                    .frame(width: width, height: height)

                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.chartGPUCore)
                    .frame(width: width, height: fillHeight)
            }

            if showLabel {
                Text("\(index)")
                    .font(.system(size: 7))
                    .foregroundStyle(.tertiary)
                    .frame(height: labelHeight)
            }
        }
    }

    private func detailCoreMiniBar(utilization: Double, height: CGFloat) -> some View {
        let fillHeight = max(1, height * utilization)

        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.chartGPUCore.opacity(0.1))
                .frame(height: height)

            RoundedRectangle(cornerRadius: 1)
                .fill(Color.chartGPUCore)
                .frame(height: fillHeight)
        }
    }

    // MARK: - Metrics Sparklines

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("GPU Metrics")
                .font(.headline)

            let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: columns, spacing: Spacing.sm) {
                sparklineCard(
                    title: "Utilization",
                    samples: viewModel.gpuDetailData.utilization.samples,
                    unit: "%",
                    color: .chartGPUCore,
                    maxY: 108
                )

                sparklineCard(
                    title: "Frequency",
                    samples: viewModel.gpuDetailData.frequencyMHz.samples,
                    unit: "MHz",
                    color: .chartFrequency,
                    maxY: nil
                )

                sparklineCard(
                    title: "Power",
                    samples: viewModel.gpuDetailData.powerWatts.samples,
                    unit: "W",
                    color: .chartGPUPower,
                    maxY: nil
                )
            }
        }
    }

    @ViewBuilder
    private func sparklineCard(title: String, samples: [(Date, Double)], unit: String, color: Color, maxY: Double?) -> some View {
        let currentValue = samples.last?.1

        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let v = currentValue {
                    Text(unit == "MHz" ? String(format: "%.0f %@", v, unit) : String(format: "%.1f %@", v, unit))
                        .font(.mono(12, weight: .medium))
                        .foregroundStyle(color)
                }
            }

            if !samples.isEmpty {
                Chart(samples, id: \.0) { point in
                    AreaMark(
                        x: .value("Time", point.0),
                        yStart: .value("Baseline", 0),
                        yEnd: .value("Value", point.1)
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
                        y: .value("Value", point.1)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .interpolationMethod(.linear)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: 0...(maxY ?? autoMaxY(samples)))
                .frame(height: 60)
                .clipped()
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.emptyStateBackground)
                    .frame(height: 60)
            }
        }
        .cardStyle()
    }

    private func autoMaxY(_ samples: [(Date, Double)]) -> Double {
        let maxVal = samples.map(\.1).max() ?? 1
        return max(maxVal * 1.15, 1)
    }

    // MARK: - P-State Frequency Distribution

    private var pStateSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Frequency Distribution")
                .font(.headline)

            Text("Time spent at each GPU frequency level")
                .font(.caption)
                .foregroundStyle(.secondary)

            let distribution = viewModel.gpuDetailData.latestPStateDistribution

            Chart(distribution) { entry in
                BarMark(
                    x: .value("Frequency", String(format: "%.0f", entry.frequencyMHz)),
                    y: .value("Residency", entry.fraction * 100)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.chartGPUCore.opacity(0.6), Color.chartGPUCore],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
                .cornerRadius(3)
            }
            .chartXAxisLabel("Frequency (MHz)")
            .chartYAxisLabel("Time (%)")
            .chartYScale(domain: 0...100)
            .frame(height: 200)
            .padding(Spacing.sm)
            .background {
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .fill(Color.cardBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .strokeBorder(Color.cardBorder, lineWidth: 1)
                    }
            }
        }
    }
}
