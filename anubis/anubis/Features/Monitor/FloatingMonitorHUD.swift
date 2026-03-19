//
//  FloatingMonitorHUD.swift
//  anubis
//

import SwiftUI
import Combine

/// Lightweight observable that drives the floating HUD from MetricsService.
/// Separate from MonitorViewModel to avoid coupling to the Monitor tab.
@MainActor
final class FloatingMonitorState: ObservableObject {
    @Published private(set) var currentMetrics: SystemMetrics?

    private let metricsService: MetricsService
    private var subscription: AnyCancellable?
    private var collectingForHUD = false

    init(metricsService: MetricsService) {
        self.metricsService = metricsService
        subscription = metricsService.$currentMetrics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] metrics in
                self?.currentMetrics = metrics
            }
    }

    func startIfNeeded() {
        guard !metricsService.isCollecting else { return }
        metricsService.startCollecting()
        collectingForHUD = true
    }

    func stopIfOurs() {
        guard collectingForHUD else { return }
        metricsService.stopCollecting()
        collectingForHUD = false
    }
}

/// Compact floating HUD for system metrics — frameless, always-on-top, semi-transparent.
struct FloatingMonitorHUD: View {
    @ObservedObject var state: FloatingMonitorState
    let onClose: () -> Void

    private var chip: ChipInfo { ChipInfo.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(chip.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if let m = state.currentMetrics {
                // CPU + GPU row
                HStack(spacing: 12) {
                    metricItem("CPU", value: pct(m.cpuUtilization), color: .chartCPU)
                    metricItem("GPU", value: pct(m.gpuUtilization), color: .chartGPU)
                }

                // Memory row
                HStack(spacing: 12) {
                    metricItem("MEM", value: Formatters.bytes(m.systemMemoryUsedBytes ?? m.memoryUsedBytes), color: .chartMemory)
                    if let power = m.systemPowerWatts {
                        metricItem("PWR", value: String(format: "%.1fW", power), color: .chartSystemPower)
                    }
                }

                // Power detail + thermal
                HStack(spacing: 12) {
                    if let gpuPower = m.gpuPowerWatts {
                        metricItem("GPU", value: String(format: "%.1fW", gpuPower), color: .chartGPUPower)
                    }
                    if let freq = m.gpuFrequencyMHz {
                        metricItem("FRQ", value: String(format: "%.0f", freq), color: .chartFrequency)
                    }
                    thermalBadge(m.thermalState)
                }
            } else {
                Text("Collecting...")
                    .font(.mono(10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(width: 200)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(.black.opacity(0.45))
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }

    private func metricItem(_ label: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)
            Text(value)
                .font(.mono(11, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    private func thermalBadge(_ state: ThermalState) -> some View {
        let (text, color): (String, Color) = {
            switch state {
            case .nominal: return ("OK", .green)
            case .fair:    return ("Fair", .yellow)
            case .serious: return ("Hot", .orange)
            case .critical: return ("CRIT", .red)
            }
        }()
        return HStack(spacing: 3) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 8))
            Text(text)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(color)
    }

    private func pct(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}

// MARK: - Floating Window Controller

@MainActor
final class FloatingMonitorWindowController {
    private var window: NSWindow?
    private var windowDelegate: FloatingWindowDelegate?
    private var hudState: FloatingMonitorState?
    private var metricsService: MetricsService?

    var isShowing: Bool { window != nil }

    /// Show from MetricsService directly (for launching from anywhere in the app)
    func show(metricsService: MetricsService, miniaturizeMainWindow: Bool = false) {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return
        }

        let state = FloatingMonitorState(metricsService: metricsService)
        state.startIfNeeded()
        self.hudState = state
        self.metricsService = metricsService

        let hudView = FloatingMonitorHUD(state: state) { [weak self] in
            self?.close()
        }
        let hostingView = NSHostingView(rootView: hudView)
        hostingView.setFrameSize(hostingView.fittingSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.canHide = false

        // Position in top-right of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - hostingView.fittingSize.width - 20
            let y = screenFrame.maxY - hostingView.fittingSize.height - 20
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        let delegate = FloatingWindowDelegate { [weak self] in
            self?.window = nil
            self?.windowDelegate = nil
            self?.hudState?.stopIfOurs()
            self?.hudState = nil
        }
        windowDelegate = delegate
        window.delegate = delegate

        window.makeKeyAndOrderFront(nil)
        self.window = window

        if miniaturizeMainWindow {
            NSApp.mainWindow?.miniaturize(nil)
        }
    }

    func close() {
        hudState?.stopIfOurs()
        hudState = nil
        window?.close()
        window = nil
        windowDelegate = nil
        // Restore any miniaturized windows
        for w in NSApp.windows where w.isMiniaturized {
            w.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

private class FloatingWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
