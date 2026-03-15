//
//  MonitorViewModel.swift
//  anubis
//
//  Created on 2026-03-15.
//

import SwiftUI
import Combine

/// Chart data container for the system monitor (no persistence, in-memory only)
struct MonitorChartData {
    var cpuUtilization: [(Date, Double)] = []
    var gpuUtilization: [(Date, Double)] = []
    var memoryGB: [(Date, Double)] = []
    var systemPower: [(Date, Double)] = []
    var gpuPower: [(Date, Double)] = []
    var cpuPower: [(Date, Double)] = []
    var gpuFrequency: [(Date, Double)] = []

    var isEmpty: Bool {
        cpuUtilization.isEmpty
    }

    var hasPowerData: Bool {
        !systemPower.isEmpty && systemPower.contains(where: { $0.1 > 0 })
    }

    static let empty = MonitorChartData()
}

/// ViewModel for standalone system monitor mode.
/// Reuses MetricsService for hardware sampling; accumulates chart data in memory only.
@MainActor
final class MonitorViewModel: ObservableObject {
    // MARK: - Published State

    @Published private(set) var isMonitoring = false
    @Published private(set) var currentMetrics: SystemMetrics?
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var chartData = MonitorChartData.empty
    @Published private(set) var latestPerCoreSnapshot: [CoreUtilization] = []
    @Published private(set) var latestGPUUtilization: Double = 0

    var hasHardwareMetrics: Bool { metricsService.isIOReportAvailable }
    var hasPowerMetrics: Bool { metricsService.isPowerMetricsAvailable }

    var formattedElapsedTime: String {
        Formatters.duration(elapsedTime)
    }

    var sampleCount: Int { chartData.cpuUtilization.count }

    // MARK: - Private

    private let metricsService: MetricsService
    private var sampleTask: Task<Void, Never>?
    private var elapsedTimer: Timer?
    private var startTime: Date?
    private var metricsSubscription: AnyCancellable?

    /// Raw samples (full resolution). Charts get a decimated view when count exceeds threshold.
    private var rawSamples = MonitorChartData.empty
    private let maxDisplayPoints = 300
    private let sampleInterval: TimeInterval = 0.5

    // MARK: - Init

    init(metricsService: MetricsService) {
        self.metricsService = metricsService
        setupMetricsSubscription()
    }

    // MARK: - Control

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        startTime = Date()

        metricsService.clearHistory()
        metricsService.startCollecting()

        // Elapsed time ticker
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.startTime else { return }
                self.elapsedTime = Date().timeIntervalSince(start)
            }
        }

        // Sample collection loop
        sampleTask = Task {
            while !Task.isCancelled && isMonitoring {
                collectSample()
                try? await Task.sleep(for: .seconds(sampleInterval))
            }
        }
    }

    func stopMonitoring() {
        isMonitoring = false
        sampleTask?.cancel()
        sampleTask = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        metricsService.stopCollecting()
    }

    func reset() {
        stopMonitoring()
        rawSamples = .empty
        chartData = .empty
        elapsedTime = 0
        startTime = nil
        currentMetrics = nil
        latestPerCoreSnapshot = []
        latestGPUUtilization = 0
    }

    // MARK: - Private

    private func setupMetricsSubscription() {
        metricsSubscription = metricsService.$currentMetrics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] metrics in
                guard let self, let metrics else { return }
                self.currentMetrics = metrics
                if let perCore = metrics.perCoreUtilization {
                    self.latestPerCoreSnapshot = perCore
                }
                self.latestGPUUtilization = metrics.gpuUtilization
            }
    }

    private func collectSample() {
        guard let metrics = metricsService.latestMetrics else { return }
        let now = metrics.timestamp

        rawSamples.cpuUtilization.append((now, metrics.cpuUtilization * 100))
        rawSamples.gpuUtilization.append((now, metrics.gpuUtilization * 100))
        rawSamples.memoryGB.append((now, Double(metrics.memoryUsedBytes) / 1e9))

        if let v = metrics.systemPowerWatts { rawSamples.systemPower.append((now, v)) }
        if let v = metrics.gpuPowerWatts { rawSamples.gpuPower.append((now, v)) }
        if let v = metrics.cpuPowerWatts { rawSamples.cpuPower.append((now, v)) }
        if let v = metrics.gpuFrequencyMHz { rawSamples.gpuFrequency.append((now, v)) }

        // Decimate for rendering if needed
        chartData = decimated(rawSamples)
    }

    /// Downsample using stride selection when point count exceeds threshold.
    /// Preserves first and last points, keeps shape by striding evenly.
    private func decimated(_ raw: MonitorChartData) -> MonitorChartData {
        var out = MonitorChartData()
        out.cpuUtilization = downsample(raw.cpuUtilization)
        out.gpuUtilization = downsample(raw.gpuUtilization)
        out.memoryGB = downsample(raw.memoryGB)
        out.systemPower = downsample(raw.systemPower)
        out.gpuPower = downsample(raw.gpuPower)
        out.cpuPower = downsample(raw.cpuPower)
        out.gpuFrequency = downsample(raw.gpuFrequency)
        return out
    }

    private func downsample(_ data: [(Date, Double)]) -> [(Date, Double)] {
        guard data.count > maxDisplayPoints else { return data }
        let stride = max(1, data.count / maxDisplayPoints)
        var result: [(Date, Double)] = []
        result.reserveCapacity(maxDisplayPoints + 1)
        for i in Swift.stride(from: 0, to: data.count - 1, by: stride) {
            result.append(data[i])
        }
        // Always include last point
        if let last = data.last {
            result.append(last)
        }
        return result
    }
}
