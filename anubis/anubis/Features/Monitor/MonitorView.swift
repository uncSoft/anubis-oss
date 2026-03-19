//
//  MonitorView.swift
//  anubis
//
//  Created on 2026-03-15.
//

import SwiftUI
import Charts

/// Standalone system monitor — shows live hardware metrics without running a benchmark.
/// Data is in-memory only; nothing is persisted after the monitor is closed.
struct MonitorView: View {
    @StateObject private var viewModel: MonitorViewModel
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    private var chip: ChipInfo { ChipInfo.current }
    private let threeColumns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    init(metricsService: MetricsService) {
        _viewModel = StateObject(wrappedValue: MonitorViewModel(metricsService: metricsService))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)

            // Stress test toolbar (only when monitoring)
            if viewModel.isMonitoring || viewModel.stressManager.anyActive {
                Divider()
                StressTestToolbar(manager: viewModel.stressManager)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.xs)

                if let warning = viewModel.stressManager.thermalWarning {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.bottom, Spacing.xs)
                }
            }

            Divider()

            if !viewModel.isMonitoring && viewModel.sampleCount == 0 {
                emptyState
            } else {
                GeometryReader { geo in
                    let chartHeight = monitorChartHeight(availableHeight: geo.size.height)

                    ScrollView {
                        LazyVGrid(columns: threeColumns, spacing: Spacing.md) {
                            // Row 1: System info | CPU Utilization | GPU Utilization
                            systemInfoCard(chartHeight: chartHeight)
                            TimelineChart(
                                title: "CPU Utilization",
                                data: viewModel.chartData.cpuUtilization,
                                color: .chartCPU,
                                unit: "%",
                                maxValue: 100,
                                chartHeight: chartHeight
                            )
                            TimelineChart(
                                title: "GPU Utilization",
                                data: viewModel.chartData.gpuUtilization,
                                color: .chartGPU,
                                unit: "%",
                                maxValue: 100,
                                chartHeight: chartHeight
                            )

                            // Row 2: Memory | CPU Cores | GPU Cores
                            MemoryTimelineChart(
                                title: "System Memory",
                                data: viewModel.chartData.memoryGB,
                                currentBytes: viewModel.currentMetrics?.systemMemoryUsedBytes ?? viewModel.currentMetrics?.memoryUsedBytes ?? 0,
                                totalBytes: viewModel.currentMetrics?.memoryTotalBytes ?? 1,
                                color: .chartMemory,
                                chartHeight: chartHeight,
                                secondaryData: viewModel.chartData.backendMemoryGB,
                                secondaryLabel: "Backend",
                                secondaryBytes: viewModel.currentMetrics?.backendProcessMemoryBytes
                            )
                            CoreUtilizationGrid(
                                snapshot: viewModel.latestPerCoreSnapshot,
                                showExpandButton: false,
                                chartHeight: chartHeight
                            ) {}
                            GPUCoreGrid(
                                gpuUtilization: viewModel.latestGPUUtilization,
                                showExpandButton: false,
                                chartHeight: chartHeight
                            ) {}

                            // Power rows (if available)
                            if viewModel.hasPowerMetrics {
                                // Row 3: System Power | GPU Power | CPU Power
                                TimelineChart(
                                    title: "System Power",
                                    data: viewModel.chartData.systemPower,
                                    color: .chartSystemPower,
                                    unit: "W",
                                    chartHeight: chartHeight
                                )
                                TimelineChart(
                                    title: "GPU Power",
                                    data: viewModel.chartData.gpuPower,
                                    color: .chartGPUPower,
                                    unit: "W",
                                    chartHeight: chartHeight
                                )
                                TimelineChart(
                                    title: "CPU Power",
                                    data: viewModel.chartData.cpuPower,
                                    color: .chartCPUPower,
                                    unit: "W",
                                    chartHeight: chartHeight
                                )

                                // Row 4: GPU Frequency
                                TimelineChart(
                                    title: "GPU Frequency",
                                    data: viewModel.chartData.gpuFrequency,
                                    color: .chartFrequency,
                                    unit: "MHz",
                                    chartHeight: chartHeight
                                )
                            }
                        }
                        .padding(Spacing.lg)
                    }
                }
            }
        }
        .onDisappear {
            viewModel.stressManager.cleanup()
            viewModel.stopMonitoring()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            VStack(spacing: Spacing.md) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)

                Text("System Monitor")
                    .font(.title2.weight(.semibold))

                VStack(spacing: 4) {
                    Text(ChipInfo.macModelName)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("\(chip.name) · \(chip.performanceCores)P + \(chip.efficiencyCores)E · \(chip.gpuCores) GPU · \(chip.unifiedMemoryGB) GB")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }

                Text("Press Start to begin recording system metrics.\nCPU, GPU, memory, power, and thermal data will be charted in real time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Button {
                if viewModel.isMonitoring {
                    viewModel.stopMonitoring()
                } else {
                    viewModel.startMonitoring()
                }
            } label: {
                Label(
                    viewModel.isMonitoring ? "Stop" : "Start",
                    systemImage: viewModel.isMonitoring ? "stop.fill" : "play.fill"
                )
            }
            .keyboardShortcut(.return, modifiers: .command)

            if viewModel.sampleCount > 0 && !viewModel.isMonitoring {
                Button {
                    viewModel.reset()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
            }

            if viewModel.isMonitoring {
                Button {
                    appState.floatingHUD.show(metricsService: appState.metricsService, miniaturizeMainWindow: true)
                } label: {
                    Label("Float", systemImage: "pip.fill")
                }
                .help("Detach as floating HUD overlay")
            }

            Spacer()

            HStack(spacing: Spacing.sm) {
                if viewModel.isMonitoring {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .shadow(color: .red.opacity(0.5), radius: 4)
                    Text("Recording")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if viewModel.elapsedTime > 0 {
                    Text(viewModel.formattedElapsedTime)
                        .font(.mono(13, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                if viewModel.sampleCount > 0 {
                    Text("\(viewModel.sampleCount) samples")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - System Info Card

    private func systemInfoCard(chartHeight: CGFloat) -> some View {
        // Total height of a TimelineChart card:
        //   Spacing.xs (8) between title and chart +
        //   headline title (~20) + chart area (chartHeight) = content
        //   + cardStyle padding (16 top + 16 bottom) = total
        // We match that by setting content height = chartHeight + 28
        VStack(alignment: .leading, spacing: Spacing.xs) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ChipInfo.macModelName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 2) {
                    Text(chip.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(chip.performanceCores)P+\(chip.efficiencyCores)E")
                        .foregroundStyle(.secondary)
                    if chip.gpuCores > 0 {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("\(chip.gpuCores)GPU")
                            .foregroundStyle(.secondary)
                    }
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(chip.unifiedMemoryGB)GB")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 10))
            }

            Divider()

            if let metrics = viewModel.currentMetrics {
                VStack(alignment: .leading, spacing: 3) {
                    monitorStat(label: "CPU", value: String(format: "%.0f%%", metrics.cpuUtilization * 100), color: .chartCPU)
                    monitorStat(label: "GPU", value: String(format: "%.0f%%", metrics.gpuUtilization * 100), color: .chartGPU)
                    monitorStat(label: "Memory", value: Formatters.bytes(metrics.systemMemoryUsedBytes ?? metrics.memoryUsedBytes), color: .chartMemory)
                    if let power = metrics.systemPowerWatts {
                        monitorStat(label: "Power", value: String(format: "%.1f W", power), color: .chartSystemPower)
                    }
                    monitorStat(label: "Thermal", value: metrics.thermalState.displayName, color: thermalColor(metrics.thermalState))
                }
            } else {
                Text("Collecting...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: chartHeight + 28)
        .cardStyle()
    }

    private func monitorStat(label: String, value: String, color: Color) -> some View {
        HStack(spacing: Spacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.mono(12, weight: .medium))
                .foregroundStyle(.primary)
        }
    }

    private func thermalColor(_ state: ThermalState) -> Color {
        switch state {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        }
    }

    // MARK: - Chart Height

    /// Compute chart height so all rows fit without scrolling.
    /// With power: 4 rows (info+utils, mem+cores, power×3, freq)
    /// Without power: 2 rows (info+utils, mem+cores)
    private func monitorChartHeight(availableHeight: CGFloat) -> CGFloat {
        let toolbarHeight: CGFloat = 44
        let available = availableHeight - toolbarHeight
        let totalRows: CGFloat = viewModel.hasPowerMetrics ? 4 : 2
        let padding: CGFloat = 48
        let gridSpacing: CGFloat = Spacing.md * (totalRows - 1)
        let usableHeight = available - padding - gridSpacing
        let perRow = usableHeight / totalRows
        // Subtract card overhead (title + padding ≈ 54px) to get chart area height
        return max(80, perRow - 54)
    }
}
