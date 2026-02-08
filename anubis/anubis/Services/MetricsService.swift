//
//  MetricsService.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation
import Combine
import Darwin

// MARK: - Background Metrics Collector

/// Performs all expensive system calls (IOKit, proc_listpids, host_processor_info)
/// off the main thread. This actor serializes access to mutable state (PID cache,
/// CPU tick tracking) while keeping the work away from MainActor.
private actor MetricsCollector {
    // ProcessMonitor replaces inline Ollama-only PID scanning
    let processMonitor = ProcessMonitor()

    // CPU tick tracking for delta calculation
    private var previousCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    /// One-time baseline sample for IOReport
    func establishBaseline(bridge: IOReportBridge) {
        _ = bridge.sample()
    }

    /// Collect a full metrics snapshot. All expensive work happens here, off MainActor.
    func collectMetrics(
        bridge: IOReportBridge,
        preferredBackend: BackendProcessType? = nil
    ) async -> SystemMetrics {
        let processInfo = ProcessInfo.processInfo
        let memoryTotal = processInfo.physicalMemory

        // Get backend process metrics via ProcessMonitor
        let backendInfo = await processMonitor.findPrimaryBackend(preferredType: preferredBackend)
        let backendMemory = backendInfo?.memoryBytes ?? 0
        let backendCPU = backendInfo?.cpuPercent ?? 0
        let backendName = backendInfo?.name

        // IOKit GPU + IOReport power/frequency read
        let hardwareMetrics = bridge.sample()

        // CPU utilization via host_processor_info
        let cpuUtilization = getCPUUtilization()

        let gpuUtilization = hardwareMetrics.isAvailable ? hardwareMetrics.gpuUtilization : 0.0

        return SystemMetrics(
            timestamp: Date(),
            gpuUtilization: gpuUtilization,
            cpuUtilization: cpuUtilization,
            memoryUsedBytes: backendMemory,
            memoryTotalBytes: Int64(memoryTotal),
            thermalState: ThermalState(from: processInfo.thermalState),
            gpuPowerWatts: hardwareMetrics.gpuPowerWatts > 0 ? hardwareMetrics.gpuPowerWatts : nil,
            cpuPowerWatts: hardwareMetrics.cpuPowerWatts > 0 ? hardwareMetrics.cpuPowerWatts : nil,
            anePowerWatts: hardwareMetrics.anePowerWatts > 0 ? hardwareMetrics.anePowerWatts : nil,
            dramPowerWatts: hardwareMetrics.dramPowerWatts > 0 ? hardwareMetrics.dramPowerWatts : nil,
            systemPowerWatts: hardwareMetrics.systemPowerWatts > 0 ? hardwareMetrics.systemPowerWatts : nil,
            gpuFrequencyMHz: hardwareMetrics.gpuFrequencyMHz > 0 ? hardwareMetrics.gpuFrequencyMHz : nil,
            backendProcessMemoryBytes: backendMemory > 0 ? backendMemory : nil,
            backendProcessCPUPercent: backendCPU > 0 ? backendCPU : nil,
            backendProcessName: backendName
        )
    }

    func resetCPUTracking() {
        previousCPUTicks = nil
    }

    func setCustomProcess(pid: pid_t, name: String) {
        Task { await processMonitor.setCustomProcess(pid: pid, name: name) }
    }

    func clearCustomProcess() {
        Task { await processMonitor.clearCustomProcess() }
    }

    func listCandidateProcesses() async -> [ProcessCandidate] {
        await processMonitor.listCandidateProcesses()
    }

    func autoDetectByPort(_ port: UInt16) async -> BackendProcessInfo? {
        await processMonitor.autoDetectByPort(port)
    }

    // MARK: - Private

    private func getCPUUtilization() -> Double {
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCPUInfo
        )

        guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else {
            return 0.0
        }

        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(numCPUInfo))
        }

        var totalUser: UInt64 = 0
        var totalSystem: UInt64 = 0
        var totalIdle: UInt64 = 0
        var totalNice: UInt64 = 0

        cpuInfo.withMemoryRebound(to: processor_cpu_load_info.self, capacity: Int(numCPUs)) { ptr in
            for i in 0..<Int(numCPUs) {
                totalUser += UInt64(ptr[i].cpu_ticks.0)
                totalSystem += UInt64(ptr[i].cpu_ticks.1)
                totalIdle += UInt64(ptr[i].cpu_ticks.2)
                totalNice += UInt64(ptr[i].cpu_ticks.3)
            }
        }

        guard let previous = previousCPUTicks else {
            previousCPUTicks = (totalUser, totalSystem, totalIdle, totalNice)
            return 0.0
        }

        let deltaUser = totalUser - previous.user
        let deltaSystem = totalSystem - previous.system
        let deltaIdle = totalIdle - previous.idle
        let deltaNice = totalNice - previous.nice

        previousCPUTicks = (totalUser, totalSystem, totalIdle, totalNice)

        let totalDelta = deltaUser + deltaSystem + deltaIdle + deltaNice
        guard totalDelta > 0 else { return 0.0 }

        let activeTime = deltaUser + deltaSystem + deltaNice
        return Double(activeTime) / Double(totalDelta)
    }
}

// MARK: - MetricsService

/// Service for collecting hardware and inference metrics
/// Integrates with IOReportBridge for GPU metrics on Apple Silicon
///
/// Expensive system calls (IOKit, proc_listpids, host_processor_info) run on a
/// background actor. Published properties are updated on MainActor. During benchmarks,
/// callers should read `latestMetrics` (cheap cached read) instead of `sampleOnce()`.
@MainActor
final class MetricsService: ObservableObject {
    // MARK: - Published State

    /// Current system metrics (updated on MainActor from background collection)
    @Published private(set) var currentMetrics: SystemMetrics?

    /// Whether metrics collection is active
    @Published private(set) var isCollecting = false

    /// Whether IOReport is available for hardware metrics
    @Published private(set) var isIOReportAvailable = false

    /// Whether power metrics (IOReport subscription) are available
    @Published private(set) var isPowerMetricsAvailable = false

    /// Polling interval in seconds
    @Published var pollingInterval: TimeInterval = 0.5

    // MARK: - Private Properties

    private var pollingTask: Task<Void, Never>?
    private var metricsHistory: [SystemMetrics] = []
    private let maxHistoryCount = 600 // 5 minutes at 0.5s intervals

    private let ioReportBridge = IOReportBridge.shared

    /// Background collector that does all expensive system calls off the main thread
    private let collector = MetricsCollector()

    // MARK: - Demo Mode Support

    /// Simulated GPU load for demo mode (ramps up/down during inference)
    private var demoSimulatedLoad: Double = 0.15
    private var demoLoadDirection: Double = 1.0

    // MARK: - Initialization

    init() {
        // In demo mode, always report IOReport as available
        isIOReportAvailable = DemoMode.isEnabled || ioReportBridge.isAvailable
        isPowerMetricsAvailable = DemoMode.isEnabled || ioReportBridge.isPowerMetricsAvailable
        setupThermalStateObserver()
    }

    // MARK: - Collection Control

    /// Start collecting metrics
    func startCollecting() {
        guard !isCollecting else { return }
        isCollecting = true

        pollingTask = Task {
            // Use synthetic metrics in demo mode
            if DemoMode.isEnabled {
                while !Task.isCancelled && isCollecting {
                    let metrics = self.generateDemoMetrics()
                    self.currentMetrics = metrics
                    self.recordMetrics(metrics)
                    try? await Task.sleep(for: .seconds(pollingInterval))
                }
                return
            }

            // Initial IOReport sample to establish baseline (on background)
            if isIOReportAvailable {
                await collector.establishBaseline(bridge: ioReportBridge)
                try? await Task.sleep(for: .milliseconds(100))
            }

            while !Task.isCancelled && isCollecting {
                // Do all expensive work on background actor
                let metrics = await collector.collectMetrics(bridge: ioReportBridge)

                // Cheap MainActor update — just assign the result
                self.currentMetrics = metrics
                self.recordMetrics(metrics)

                try? await Task.sleep(for: .seconds(pollingInterval))
            }
        }
    }

    /// Stop collecting metrics
    func stopCollecting() {
        isCollecting = false
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Get historical metrics for charting
    func getHistory() -> [SystemMetrics] {
        metricsHistory
    }

    /// Clear historical metrics
    func clearHistory() {
        metricsHistory.removeAll()
        Task { await collector.resetCPUTracking() }
    }

    /// Returns the latest cached metrics without triggering any system calls.
    /// Use this during benchmarks to avoid blocking the main thread.
    var latestMetrics: SystemMetrics? {
        currentMetrics
    }

    /// Set a custom process to monitor (overrides auto-detection)
    func setCustomProcess(pid: pid_t, name: String) {
        Task { await collector.setCustomProcess(pid: pid, name: name) }
    }

    /// Clear the custom process override
    func clearCustomProcess() {
        Task { await collector.clearCustomProcess() }
    }

    /// List candidate processes for the process picker UI
    func listCandidateProcesses() async -> [ProcessCandidate] {
        await collector.listCandidateProcesses()
    }

    /// Auto-detect backend by the port it's listening on.
    /// Call once when a benchmark starts to lock onto the actual server process.
    func autoDetectByPort(_ port: UInt16) async -> BackendProcessInfo? {
        await collector.autoDetectByPort(port)
    }

    /// Take a single sample. If collecting is active, returns cached value (free).
    /// Otherwise performs a full collection on the background actor.
    func sampleOnce() async -> SystemMetrics {
        if let cached = currentMetrics, isCollecting {
            return cached
        }
        // Use demo metrics in demo mode
        if DemoMode.isEnabled {
            return generateDemoMetrics()
        }
        return await collector.collectMetrics(bridge: ioReportBridge)
    }

    // MARK: - Private Methods

    private func recordMetrics(_ metrics: SystemMetrics) {
        metricsHistory.append(metrics)
        if metricsHistory.count > maxHistoryCount {
            metricsHistory.removeFirst()
        }
    }

    private func setupThermalStateObserver() {
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                let state = ProcessInfo.processInfo.thermalState
                if state == .serious || state == .critical {
                    self?.pollingInterval = 1.0
                } else {
                    self?.pollingInterval = 0.5
                }
            }
        }
    }
}

// MARK: - Metrics Snapshot for Benchmarking

extension MetricsService {
    /// Get current metrics along with inference data for benchmark recording
    func snapshotForBenchmark(
        tokensGenerated: Int,
        elapsedTime: TimeInterval
    ) -> BenchmarkMetricsSnapshot {
        let metrics = currentMetrics ?? SystemMetrics(
            timestamp: Date(),
            gpuUtilization: 0,
            cpuUtilization: 0,
            memoryUsedBytes: 0,
            memoryTotalBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            thermalState: ThermalState(from: ProcessInfo.processInfo.thermalState)
        )
        let tokensPerSecond = elapsedTime > 0 ? Double(tokensGenerated) / elapsedTime : 0

        return BenchmarkMetricsSnapshot(
            timestamp: Date(),
            gpuUtilization: metrics.gpuUtilization,
            cpuUtilization: metrics.cpuUtilization,
            memoryUsedBytes: metrics.memoryUsedBytes,
            memoryTotalBytes: metrics.memoryTotalBytes,
            thermalState: metrics.thermalState,
            tokensGenerated: tokensGenerated,
            cumulativeTokensPerSecond: tokensPerSecond
        )
    }
}

/// Snapshot of metrics for benchmark recording
struct BenchmarkMetricsSnapshot: Sendable {
    let timestamp: Date
    let gpuUtilization: Double
    let cpuUtilization: Double
    let memoryUsedBytes: Int64
    let memoryTotalBytes: Int64
    let thermalState: ThermalState
    let tokensGenerated: Int
    let cumulativeTokensPerSecond: Double
}

// MARK: - Demo Mode Metrics Generation

extension MetricsService {
    /// Generate synthetic metrics for demo mode
    func generateDemoMetrics() -> SystemMetrics {
        // Update simulated load with smooth ramping
        updateDemoLoad()

        // Add some noise for realism
        let noise = Double.random(in: -0.03...0.03)

        // GPU utilization correlates with simulated load
        let gpuUtilization = min(1.0, max(0.0, demoSimulatedLoad * 0.75 + noise + 0.1))

        // CPU utilization is typically lower than GPU during inference
        let cpuUtilization = min(1.0, max(0.0, demoSimulatedLoad * 0.35 + noise + 0.08))

        // Memory usage: base + model size simulation
        let totalMemory = Int64(ProcessInfo.processInfo.physicalMemory)
        let baseMemory = Int64(4 * 1024 * 1024 * 1024) // 4GB base
        let modelMemory = Int64(Double(2 * 1024 * 1024 * 1024) * demoSimulatedLoad) // Up to 2GB
        let memoryUsed = min(baseMemory + modelMemory, totalMemory - 1024 * 1024 * 1024)

        // Synthetic power metrics
        let gpuPower = demoSimulatedLoad * 15.0 + Double.random(in: -1...1)  // Up to ~15W GPU
        let cpuPower = demoSimulatedLoad * 5.0 + Double.random(in: -0.5...0.5)
        let dramPower = 1.5 + Double.random(in: -0.2...0.2)
        let anePower = demoSimulatedLoad * 0.5

        return SystemMetrics(
            timestamp: Date(),
            gpuUtilization: gpuUtilization,
            cpuUtilization: cpuUtilization,
            memoryUsedBytes: memoryUsed,
            memoryTotalBytes: totalMemory,
            thermalState: .nominal,
            gpuPowerWatts: max(0, gpuPower),
            cpuPowerWatts: max(0, cpuPower),
            anePowerWatts: max(0, anePower),
            dramPowerWatts: max(0, dramPower),
            systemPowerWatts: max(0, gpuPower + cpuPower + dramPower + anePower),
            gpuFrequencyMHz: 1000 + demoSimulatedLoad * 400 + Double.random(in: -50...50),
            backendProcessMemoryBytes: memoryUsed,
            backendProcessCPUPercent: cpuUtilization * 100,
            backendProcessName: "Demo"
        )
    }

    /// Update simulated load with smooth ramping
    private func updateDemoLoad() {
        // Randomly change direction occasionally
        if Double.random(in: 0...1) < 0.08 {
            demoLoadDirection *= -1
        }

        // Update load with momentum
        demoSimulatedLoad += demoLoadDirection * Double.random(in: 0.02...0.06)

        // Clamp and bounce at boundaries
        if demoSimulatedLoad >= 0.8 {
            demoSimulatedLoad = 0.8
            demoLoadDirection = -1
        } else if demoSimulatedLoad <= 0.15 {
            demoSimulatedLoad = 0.15
            demoLoadDirection = 1
        }
    }

    /// Spike the load for demo mode (call when inference starts)
    func demoBumpLoad() {
        if DemoMode.isEnabled {
            demoSimulatedLoad = max(demoSimulatedLoad, 0.5)
            demoLoadDirection = 1
        }
    }
}
