//
//  StressTestToolbar.swift
//  anubis
//

import SwiftUI

/// Stress test controls — CPU/GPU/Memory toggles, status badges, countdown, Stop All.
struct StressTestToolbar: View {
    @ObservedObject var manager: StressTestManager
    @State private var showingInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.sm) {
                // CPU button with scope picker
                Menu {
                    ForEach(CPUStressScope.allCases) { scope in
                        Button {
                            manager.cpuScope = scope
                            if !manager.cpuActive {
                                manager.toggleCPU()
                            }
                        } label: {
                            HStack {
                                Text(scope.rawValue)
                                if manager.cpuActive && manager.cpuScope == scope {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    if manager.cpuActive {
                        Divider()
                        Button("Stop CPU") {
                            manager.toggleCPU()
                        }
                    }
                } label: {
                    Label("CPU", systemImage: "cpu")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // GPU button with stress level picker
                Menu {
                    ForEach(GPUStressLevel.allCases) { level in
                        Button {
                            manager.gpuStressLevel = level
                            if !manager.gpuActive {
                                manager.toggleGPU()
                            }
                        } label: {
                            HStack {
                                Text(level.rawValue)
                                if manager.gpuActive && manager.gpuStressLevel == level {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    if manager.gpuActive {
                        Divider()
                        Button("Stop GPU") {
                            manager.toggleGPU()
                        }
                    }
                } label: {
                    Label("GPU", systemImage: "gpu")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(manager.gpuWorker == nil)

                // Memory button with pressure level picker
                Menu {
                    ForEach(MemoryPressureLevel.allCases) { level in
                        Button {
                            manager.memoryPressureLevel = level
                            if !manager.memoryActive {
                                manager.toggleMemory()
                            }
                        } label: {
                            HStack {
                                Text(level.rawValue)
                                if manager.memoryActive && manager.memoryPressureLevel == level {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    if manager.memoryActive {
                        Divider()
                        Button("Stop Memory") {
                            manager.toggleMemory()
                        }
                    }
                } label: {
                    Label("Memory", systemImage: "memorychip")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Info button
                Button {
                    showingInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
                    stressInfoPopover
                }

                if manager.anyActive {
                    Divider()
                        .frame(height: 16)

                    statusBadges

                    Divider()
                        .frame(height: 16)

                    Text(formattedCountdown)
                        .font(.mono(12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        manager.stopAll()
                    } label: {
                        Label("Stop All", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                } else {
                    Text("Select a stress test to begin")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Spacer()
                }
            }

            // Downgrade notice
            if let notice = manager.gpuDowngradeNotice {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Info Popover

    private var stressInfoPopover: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Stress Tests")
                .font(.headline)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                infoSection(
                    icon: "cpu",
                    title: "CPU",
                    detail: "Spawns one `yes` process per core to saturate CPU.\nChoose All Cores, P-Cores, E-Cores, or Single Core."
                )
                infoSection(
                    icon: "dot.scope.laptopcomputer",
                    title: "GPU",
                    detail: "Mandelbrot fractal zoom via Metal compute shader. Opens in a separate window.\nMultiple intensity levels control iterations, supersampling, and passes per frame."
                )
                infoSection(
                    icon: "memorychip",
                    title: "Memory",
                    detail: "Allocates memory then continuously streams through it with memcpy to saturate the memory bus.\nReports measured bandwidth (GB/s) vs chip theoretical max (\(formattedTheoreticalBW))."
                )
            }

            Divider()

            Text("GPU Stress Levels")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                ForEach(GPUStressLevel.allCases) { level in
                    HStack(spacing: 6) {
                        Text(level.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 55, alignment: .leading)
                        Text("\(level.maxIterations) iter")
                            .font(.mono(10))
                        Text("\(level.supersampling)x SS")
                            .font(.mono(10))
                        Text("\(level.passesPerFrame) pass\(level.passesPerFrame > 1 ? "es" : "")")
                            .font(.mono(10))
                    }
                    .foregroundStyle(level == manager.gpuStressLevel ? .primary : .secondary)
                }
            }

            Divider()

            Text("Memory Pressure Levels")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                ForEach(MemoryPressureLevel.allCases) { level in
                    HStack(spacing: 6) {
                        Text(level.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 100, alignment: .leading)
                        Text("\(level.threadCount) threads")
                            .font(.mono(10))
                    }
                    .foregroundStyle(level == manager.memoryPressureLevel ? .primary : .secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Label("Auto-stops after 5 minutes", systemImage: "timer")
                Label("Auto-stops at critical thermal state", systemImage: "thermometer.sun.fill")
                Label("Auto-downgrades GPU if FPS < 5 for 3 sec", systemImage: "arrow.down.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 360)
        .frame(height: 600)
    }

    private func infoSection(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Status Badges

    @ViewBuilder
    private var statusBadges: some View {
        HStack(spacing: Spacing.xs) {
            if manager.cpuActive {
                badge(
                    "CPU \(manager.cpuCoreCount) cores",
                    color: .chartCPU
                )
            }
            if manager.gpuActive {
                badge(
                    "GPU \(manager.gpuFPS) FPS (\(manager.gpuStressLevel.rawValue))",
                    color: .chartGPU
                )
            }
            if manager.memoryActive {
                badge(
                    "MEM \(formattedMemory) @ \(formattedBandwidth)",
                    color: .chartMemory
                )
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.secondary)
    }

    private var formattedCountdown: String {
        let minutes = manager.remainingSeconds / 60
        let seconds = manager.remainingSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var formattedMemory: String {
        let gb = Double(manager.memoryAllocatedBytes) / 1e9
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        } else {
            return String(format: "%.0f MB", gb * 1000)
        }
    }

    private var formattedBandwidth: String {
        let bw = manager.memoryBandwidthGBs
        if bw > 0 {
            return String(format: "%.1f GB/s", bw)
        } else {
            return "measuring..."
        }
    }

    private var formattedTheoreticalBW: String {
        let bw = ChipInfo.current.memoryBandwidthGBs
        return String(format: "%.0f GB/s", bw)
    }
}
