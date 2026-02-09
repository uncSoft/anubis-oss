//
//  CoreUtilizationView.swift
//  anubis
//
//  Created on 2026-02-08.
//

import SwiftUI
import Charts

// MARK: - Inline Core Utilization Grid

/// Card-sized view showing a grid of vertical utilization bars, one per core.
/// P-cores and E-cores are color-coded. Fits in the ChartGrid alongside other charts.
struct CoreUtilizationGrid: View {
    let snapshot: [CoreUtilization]
    let onExpand: () -> Void

    private var eCores: [CoreUtilization] {
        snapshot.filter { $0.coreType == .efficiency }.sorted { $0.coreIndex < $1.coreIndex }
    }

    private var pCores: [CoreUtilization] {
        snapshot.filter { $0.coreType == .performance }.sorted { $0.coreIndex < $1.coreIndex }
    }

    private var chipSummary: String {
        let chip = ChipInfo.current
        if chip.performanceCores > 0 || chip.efficiencyCores > 0 {
            return "\(chip.performanceCores)P + \(chip.efficiencyCores)E"
        }
        return "\(snapshot.count) cores"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // Header
            HStack {
                Text("CPU Cores")
                    .font(.headline)
                Spacer()
                Text(chipSummary)
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
                .help("Open core detail window")
            }

            if snapshot.isEmpty {
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
                Image(systemName: "cpu")
                    .font(.title2)
                    .foregroundStyle(.quaternary)
                Text("Waiting for data...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(height: 150)
    }

    private var coreBarGrid: some View {
        GeometryReader { geo in
            let totalCores = snapshot.count
            let barSpacing: CGFloat = totalCores > 20 ? 2 : 3
            let labelHeight: CGFloat = 14
            let availableWidth = geo.size.width
            let dividerWidth: CGFloat = eCores.isEmpty || pCores.isEmpty ? 0 : 8
            let totalSpacing = CGFloat(max(0, totalCores - 1)) * barSpacing + dividerWidth
            let barWidth = max(4, (availableWidth - totalSpacing) / CGFloat(totalCores))
            let barAreaHeight = geo.size.height - labelHeight - 4

            HStack(alignment: .bottom, spacing: barSpacing) {
                // E-cores
                ForEach(eCores, id: \.coreIndex) { core in
                    coreBar(core: core, width: barWidth, height: barAreaHeight, labelHeight: labelHeight)
                }

                // Subtle divider between E and P
                if !eCores.isEmpty && !pCores.isEmpty {
                    Rectangle()
                        .fill(Color.separator)
                        .frame(width: 1, height: barAreaHeight * 0.6)
                        .padding(.horizontal, 2)
                        .padding(.bottom, labelHeight + 4)
                }

                // P-cores
                ForEach(pCores, id: \.coreIndex) { core in
                    coreBar(core: core, width: barWidth, height: barAreaHeight, labelHeight: labelHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: 150)
    }

    private func coreBar(core: CoreUtilization, width: CGFloat, height: CGFloat, labelHeight: CGFloat) -> some View {
        let color: Color = core.coreType == .performance ? .chartPCore : .chartECore
        let fillHeight = max(2, height * core.utilization)

        return VStack(spacing: 2) {
            ZStack(alignment: .bottom) {
                // Background track
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(0.1))
                    .frame(width: width, height: height)

                // Fill bar
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: width, height: fillHeight)
            }

            // Core index label
            Text("\(core.coreIndex)")
                .font(.system(size: 7))
                .foregroundStyle(.tertiary)
                .frame(height: labelHeight)
        }
    }
}

// MARK: - Core Detail View (Pop-Out Window)

/// Per-core CPU detail window with sparklines grouped by P/E section.
struct CoreDetailView: View {
    @ObservedObject var viewModel: BenchmarkViewModel

    private var chip: ChipInfo { ChipInfo.current }

    private var eCoreIndices: [Int] {
        viewModel.perCoreData.cores.values
            .filter { $0.coreType == .efficiency }
            .map(\.coreIndex)
            .sorted()
    }

    private var pCoreIndices: [Int] {
        viewModel.perCoreData.cores.values
            .filter { $0.coreType == .performance }
            .map(\.coreIndex)
            .sorted()
    }

    private var avgPUtil: Double {
        let pCores = viewModel.latestPerCoreSnapshot.filter { $0.coreType == .performance }
        guard !pCores.isEmpty else { return 0 }
        return pCores.map(\.utilization).reduce(0, +) / Double(pCores.count) * 100
    }

    private var avgEUtil: Double {
        let eCores = viewModel.latestPerCoreSnapshot.filter { $0.coreType == .efficiency }
        guard !eCores.isEmpty else { return 0 }
        return eCores.map(\.utilization).reduce(0, +) / Double(eCores.count) * 100
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chip.name)
                        .font(.headline)
                    Text("\(chip.performanceCores)P + \(chip.efficiencyCores)E cores")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                // Summary stats
                HStack(spacing: Spacing.md) {
                    VStack(spacing: 2) {
                        Text("P-Core Avg")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.0f%%", avgPUtil))
                            .font(.mono(14, weight: .semibold))
                            .foregroundStyle(Color.chartPCore)
                    }
                    VStack(spacing: 2) {
                        Text("E-Core Avg")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.0f%%", avgEUtil))
                            .font(.mono(14, weight: .semibold))
                            .foregroundStyle(Color.chartECore)
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
                    // P-Cores section
                    if !pCoreIndices.isEmpty {
                        coreSection(title: "Performance Cores", indices: pCoreIndices, color: .chartPCore)
                    }

                    // E-Cores section
                    if !eCoreIndices.isEmpty {
                        coreSection(title: "Efficiency Cores", indices: eCoreIndices, color: .chartECore)
                    }
                }
                .padding(Spacing.md)
            }
        }
    }

    @ViewBuilder
    private func coreSection(title: String, indices: [Int], color: Color) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(.headline)

            let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: columns, spacing: Spacing.sm) {
                ForEach(indices, id: \.self) { idx in
                    coreSparklineCard(index: idx, color: color)
                }
            }
        }
    }

    @ViewBuilder
    private func coreSparklineCard(index: Int, color: Color) -> some View {
        let series = viewModel.perCoreData.cores[index]
        let currentUtil = viewModel.latestPerCoreSnapshot.first(where: { $0.coreIndex == index })?.utilization ?? 0

        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Core \(index)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", currentUtil * 100))
                    .font(.mono(12, weight: .medium))
                    .foregroundStyle(color)
            }

            if let series = series, !series.samples.isEmpty {
                Chart(series.samples, id: \.0) { point in
                    AreaMark(
                        x: .value("Time", point.0),
                        yStart: .value("Baseline", 0),
                        yEnd: .value("Util", point.1)
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
                        y: .value("Util", point.1)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .interpolationMethod(.linear)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: 0...108)
                .frame(height: 40)
                .clipped()
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.emptyStateBackground)
                    .frame(height: 40)
            }
        }
        .cardStyle()
    }
}
