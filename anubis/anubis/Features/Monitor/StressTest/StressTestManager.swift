//
//  StressTestManager.swift
//  anubis
//

import SwiftUI
import Combine
import MetalKit

/// Orchestrates CPU, GPU, and Memory stress tests with safety mechanisms.
@MainActor
final class StressTestManager: ObservableObject {
    // MARK: - Published State

    @Published private(set) var cpuActive = false
    @Published private(set) var gpuActive = false
    @Published private(set) var memoryActive = false
    @Published var cpuScope: CPUStressScope = .allCores
    @Published var gpuStressLevel: GPUStressLevel = .medium {
        didSet { gpuWorker?.stressLevel = gpuStressLevel }
    }
    @Published var memoryPressureLevel: MemoryPressureLevel = .moderate {
        didSet { memoryWorker.pressureLevel = memoryPressureLevel }
    }
    @Published private(set) var gpuFPS: Int = 0
    @Published private(set) var memoryBandwidthGBs: Double = 0
    @Published private(set) var remainingSeconds: Int = 300  // 5 minutes
    @Published private(set) var thermalWarning: String?
    @Published private(set) var gpuDowngradeNotice: String?

    var anyActive: Bool { cpuActive || gpuActive || memoryActive }
    var cpuCoreCount: Int { cpuWorker.coreCount }
    var memoryAllocatedBytes: Int64 { memoryWorker.allocatedBytes }

    // MARK: - Workers

    let cpuWorker = CPUStressWorker()
    let gpuWorker: GPUStressWorker?
    let memoryWorker = MemoryStressWorker()

    // MARK: - GPU Window

    private var gpuWindow: NSWindow?
    private var gpuWindowDelegate: GPUWindowDelegate?
    private var isClosingGPUWindow = false

    // MARK: - Private

    private var countdownTimer: Timer?
    private let maxDuration = 300  // 5 minutes
    private var terminateObserver: Any?
    private var fpsUpdateTimer: Timer?

    // MARK: - Init

    init() {
        let worker = GPUStressWorker.create()
        gpuWorker = worker
        worker?.stressLevel = gpuStressLevel
        worker?.onFPSUpdate = { [weak self] fps in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.gpuFPS = fps
                self.gpuWindow?.title = "GPU Stress — Mandelbrot — \(fps) FPS (\(self.gpuStressLevel.rawValue))"
            }
        }
        worker?.onAutoDowngrade = { [weak self] newLevel in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.gpuStressLevel = newLevel
                self.gpuDowngradeNotice = "GPU auto-downgraded to \(newLevel.rawValue) (unresponsive)"
                // Clear notice after 5 seconds
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    self?.gpuDowngradeNotice = nil
                }
            }
        }

        memoryWorker.onBandwidthUpdate = { [weak self] gbps in
            Task { @MainActor [weak self] in
                self?.memoryBandwidthGBs = gbps
            }
        }

        // Cleanup on app quit
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cpuWorker.stop()
            self?.gpuWorker?.stop()
            self?.memoryWorker.stop()
        }
    }

    deinit {
        if let observer = terminateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - CPU

    func toggleCPU() {
        if cpuActive {
            stopCPU()
        } else {
            startCPU()
        }
    }

    private func startCPU() {
        cpuWorker.start(scope: cpuScope)
        cpuActive = true
        startCountdownIfNeeded()
    }

    private func stopCPU() {
        cpuWorker.stop()
        cpuActive = false
        stopCountdownIfIdle()
    }

    // MARK: - GPU

    func toggleGPU() {
        if gpuActive {
            stopGPU()
        } else {
            startGPU()
        }
    }

    private func startGPU() {
        guard let worker = gpuWorker else { return }
        showGPUWindow(worker: worker)
        worker.start()
        gpuActive = true
        gpuDowngradeNotice = nil
        startCountdownIfNeeded()
    }

    private func stopGPU() {
        // Stop worker first (detaches delegate, prevents further draw calls)
        gpuWorker?.stop()
        gpuActive = false
        gpuFPS = 0
        gpuDowngradeNotice = nil
        closeGPUWindow()
        stopCountdownIfIdle()
    }

    // MARK: - GPU Window

    private func showGPUWindow(worker: GPUStressWorker) {
        if gpuWindow != nil { return }

        let mtkView = MTKView()
        worker.setupView(mtkView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GPU Stress — Mandelbrot"
        window.contentView = mtkView
        window.isReleasedWhenClosed = false
        window.center()

        let delegate = GPUWindowDelegate { [weak self] in
            guard let self, !self.isClosingGPUWindow else { return }
            // Window is closing via user click — stop the worker but don't re-close
            self.gpuWorker?.stop()
            self.gpuActive = false
            self.gpuFPS = 0
            self.gpuDowngradeNotice = nil
            self.gpuWindow = nil
            self.gpuWindowDelegate = nil
            self.stopCountdownIfIdle()
        }
        gpuWindowDelegate = delegate
        window.delegate = delegate

        window.makeKeyAndOrderFront(nil)
        gpuWindow = window
    }

    private func closeGPUWindow() {
        guard let window = gpuWindow else {
            gpuWindowDelegate = nil
            return
        }
        isClosingGPUWindow = true
        window.close()
        gpuWindow = nil
        gpuWindowDelegate = nil
        isClosingGPUWindow = false
    }

    // MARK: - Memory

    func toggleMemory() {
        if memoryActive {
            stopMemory()
        } else {
            startMemory()
        }
    }

    private func startMemory() {
        memoryWorker.start()
        memoryActive = true
        startCountdownIfNeeded()
    }

    private func stopMemory() {
        memoryWorker.stop()
        memoryActive = false
        memoryBandwidthGBs = 0
        stopCountdownIfIdle()
    }

    // MARK: - Stop All

    func stopAll() {
        stopCPU()
        stopGPU()
        stopMemory()
        thermalWarning = nil
    }

    /// Full cleanup — call on view disappear
    func cleanup() {
        stopAll()
    }

    // MARK: - Thermal Watchdog

    func checkThermalState(_ state: ThermalState) {
        switch state {
        case .critical:
            thermalWarning = "Critical thermal state — stopping all stress tests"
            stopAll()
        case .serious:
            thermalWarning = "Serious thermal pressure detected"
        case .fair:
            thermalWarning = nil
        case .nominal:
            thermalWarning = nil
        }
    }

    // MARK: - Countdown Timer

    private func startCountdownIfNeeded() {
        guard countdownTimer == nil else { return }
        remainingSeconds = maxDuration
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.remainingSeconds -= 1
                if self.remainingSeconds <= 0 {
                    self.stopAll()
                }
            }
        }
    }

    private func stopCountdownIfIdle() {
        guard !anyActive else { return }
        countdownTimer?.invalidate()
        countdownTimer = nil
        remainingSeconds = maxDuration
    }
}

// MARK: - GPU Window Delegate

private class GPUWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
