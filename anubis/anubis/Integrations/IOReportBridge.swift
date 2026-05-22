//
//  IOReportBridge.swift
//  anubis
//
//  Created on 2026-01-25.
//  Rewritten for OSS: uses real IOReport subscription API for power/frequency metrics.
//

import Foundation
import IOKit
import os

// MARK: - IOReport Dynamic Bindings

/// Dynamically loaded IOReport functions from /usr/lib/libIOReport.dylib.
/// These are not publicly documented but are stable across macOS releases and used by
/// first-party tools (powermetrics, asitop, macmon).
///
/// Signatures verified against socpowerbuddy_swift and macmon (Rust).
private struct IOReportFunctions {
    // IOReportCopyChannelsInGroup(group, subgroup, 0, 0, 0)
    typealias CopyChannelsInGroupFn = @convention(c) (NSString, NSString?, UInt64, UInt64, UInt64) -> NSMutableDictionary?

    // IOReportMergeChannels(target, source, nil)
    typealias MergeChannelsFn = @convention(c) (NSMutableDictionary, NSMutableDictionary, CFTypeRef?) -> Void

    // IOReportCreateSubscription(nil, channels, &subbedChannels, 0, nil)
    // Third param is a POINTER — IOReport writes the subscribed channels dict ref into it.
    typealias CreateSubscriptionFn = @convention(c) (AnyObject?, NSMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> UnsafeMutableRawPointer?

    // IOReportCreateSamples(subscription, subbedChannels, nil) — returns +1 (Create rule)
    typealias CreateSamplesFn = @convention(c) (UnsafeMutableRawPointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?

    // IOReportCreateSamplesDelta(prev, curr, nil) — returns +1 (Create rule)
    typealias CreateSamplesDeltaFn = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?

    // Channel accessors — return +0 (borrowed refs), NSString? is safe for that
    typealias ChannelGetChannelNameFn = @convention(c) (NSDictionary) -> NSString?
    typealias ChannelGetGroupFn = @convention(c) (NSDictionary) -> NSString?
    typealias ChannelGetSubGroupFn = @convention(c) (NSDictionary) -> NSString?
    typealias SimpleGetIntegerValueFn = @convention(c) (NSDictionary, Int32) -> Int64
    typealias StateGetCountFn = @convention(c) (NSDictionary) -> Int32
    typealias StateGetResidencyFn = @convention(c) (NSDictionary, Int32) -> Int64
    typealias StateGetNameForIndexFn = @convention(c) (NSDictionary, Int32) -> NSString?
    typealias IterateFn = @convention(c) (NSDictionary, @convention(block) (NSDictionary) -> Int32) -> Void

    let copyChannelsInGroup: CopyChannelsInGroupFn
    let mergeChannels: MergeChannelsFn
    let createSubscription: CreateSubscriptionFn
    let createSamples: CreateSamplesFn
    let createSamplesDelta: CreateSamplesDeltaFn
    let channelGetChannelName: ChannelGetChannelNameFn
    let channelGetGroup: ChannelGetGroupFn
    let channelGetSubGroup: ChannelGetSubGroupFn
    let simpleGetIntegerValue: SimpleGetIntegerValueFn
    let stateGetCount: StateGetCountFn
    let stateGetResidency: StateGetResidencyFn
    let stateGetNameForIndex: StateGetNameForIndexFn
    let iterate: IterateFn

    static func load() -> IOReportFunctions? {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else {
            Log.metrics.warning("Failed to load libIOReport.dylib")
            return nil
        }

        func sym<T>(_ name: String) -> T? {
            guard let ptr = dlsym(handle, name) else {
                Log.metrics.warning("Missing IOReport symbol: \(name)")
                return nil
            }
            return unsafeBitCast(ptr, to: T.self)
        }

        guard let copyChannelsInGroup: CopyChannelsInGroupFn = sym("IOReportCopyChannelsInGroup"),
              let mergeChannels: MergeChannelsFn = sym("IOReportMergeChannels"),
              let createSubscription: CreateSubscriptionFn = sym("IOReportCreateSubscription"),
              let createSamples: CreateSamplesFn = sym("IOReportCreateSamples"),
              let createSamplesDelta: CreateSamplesDeltaFn = sym("IOReportCreateSamplesDelta"),
              let channelGetChannelName: ChannelGetChannelNameFn = sym("IOReportChannelGetChannelName"),
              let channelGetGroup: ChannelGetGroupFn = sym("IOReportChannelGetGroup"),
              let channelGetSubGroup: ChannelGetSubGroupFn = sym("IOReportChannelGetSubGroup"),
              let simpleGetIntegerValue: SimpleGetIntegerValueFn = sym("IOReportSimpleGetIntegerValue"),
              let stateGetCount: StateGetCountFn = sym("IOReportStateGetCount"),
              let stateGetResidency: StateGetResidencyFn = sym("IOReportStateGetResidency"),
              let stateGetNameForIndex: StateGetNameForIndexFn = sym("IOReportStateGetNameForIndex"),
              let iterate: IterateFn = sym("IOReportIterate") else {
            return nil
        }

        return IOReportFunctions(
            copyChannelsInGroup: copyChannelsInGroup,
            mergeChannels: mergeChannels,
            createSubscription: createSubscription,
            createSamples: createSamples,
            createSamplesDelta: createSamplesDelta,
            channelGetChannelName: channelGetChannelName,
            channelGetGroup: channelGetGroup,
            channelGetSubGroup: channelGetSubGroup,
            simpleGetIntegerValue: simpleGetIntegerValue,
            stateGetCount: stateGetCount,
            stateGetResidency: stateGetResidency,
            stateGetNameForIndex: stateGetNameForIndex,
            iterate: iterate
        )
    }
}

// MARK: - IOReportBridge

/// Bridge to hardware metrics on Apple Silicon.
///
/// Uses two IOReport subscriptions:
///   1. Energy Model → power (GPU, CPU, ANE, DRAM) via simple-integer delta
///   2. GPU Stats / GPU Performance States → GPU frequency via state residency delta
///
/// Falls back to IORegistry AGXAccelerator for GPU utilization.
final class IOReportBridge {
    // MARK: - Singleton

    static let shared = IOReportBridge()

    // MARK: - Properties

    private var gpuServiceAvailable: Bool = false
    private var acceleratorService: io_service_t = 0
    private let fns: IOReportFunctions?

    // Energy Model subscription (power)
    private var energySub: UnsafeMutableRawPointer?
    private var energySubbed: CFMutableDictionary?
    private var energyPrevSample: CFDictionary?
    private var energyPrevTime: Date?
    private var energyReady: Bool = false

    // GPU Stats subscription (frequency)
    private var gpuStatsSub: UnsafeMutableRawPointer?
    private var gpuStatsSubbed: CFMutableDictionary?
    private var gpuStatsPrevSample: CFDictionary?
    private var gpuStatsReady: Bool = false
    private var hasLoggedGpuStats: Bool = false
    private var hasLoggedEnergy: Bool = false

    // GPU frequency table from IORegistry (MHz values for each P-state)
    private var gpuFreqTable: [Double] = []

    // MARK: - Initialization

    private init() {
        fns = IOReportFunctions.load()

        // Now safe to use self
        gpuServiceAvailable = setupGPUService()

        if let fns = fns {
            energyReady = setupEnergySubscription(fns: fns)
            gpuStatsReady = setupGPUStatsSubscription(fns: fns)
        }

        // Read GPU frequency table from IORegistry
        gpuFreqTable = Self.readGPUFrequencyTable()

        let gpuAvail = gpuServiceAvailable
        let eReady = energyReady
        let gReady = gpuStatsReady
        let freqCount = gpuFreqTable.count
        Log.metrics.info("IOReportBridge initialized - GPU service: \(gpuAvail), Energy: \(eReady), GPU Stats: \(gReady), freq table: \(freqCount) states")
        if !gpuFreqTable.isEmpty {
            Log.metrics.info("GPU frequency table (MHz): \(self.gpuFreqTable, privacy: .public)")
        }
    }

    deinit {
        if acceleratorService != 0 {
            IOObjectRelease(acceleratorService)
        }
    }

    // MARK: - Subscription Setup

    private func setupGPUService() -> Bool {
        let services = ["AGXAccelerator", "AGPM", "AppleM1GPU", "AppleM2GPU", "AppleM3GPU"]

        for serviceName in services {
            if let matching = IOServiceMatching(serviceName) {
                var iterator: io_iterator_t = 0
                let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)

                if result == KERN_SUCCESS {
                    let service = IOIteratorNext(iterator)
                    IOObjectRelease(iterator)

                    if service != 0 {
                        acceleratorService = service
                        Log.metrics.debug("Found GPU service: \(serviceName)")
                        return true
                    }
                } else {
                    IOObjectRelease(iterator)
                }
            }
        }

        Log.metrics.warning("No GPU service found via IOKit")
        return false
    }

    private func setupEnergySubscription(fns: IOReportFunctions) -> Bool {
        guard let channels = fns.copyChannelsInGroup("Energy Model" as NSString, nil, 0, 0, 0) else {
            Log.metrics.warning("IOReport: no channels for Energy Model")
            return false
        }

        var subbedRef: Unmanaged<CFMutableDictionary>?
        guard let sub = fns.createSubscription(nil, channels, &subbedRef, 0, nil) else {
            Log.metrics.warning("IOReport: failed to create Energy subscription")
            return false
        }
        guard let subbed = subbedRef?.takeRetainedValue() else {
            Log.metrics.warning("IOReport: Energy subscription created but no channels returned")
            return false
        }

        self.energySub = sub
        self.energySubbed = subbed

        if let initial = fns.createSamples(sub, subbed, nil)?.takeRetainedValue() {
            self.energyPrevSample = initial
            self.energyPrevTime = Date()
        }

        Log.metrics.info("IOReport: Energy Model subscription ready")
        return true
    }

    private func setupGPUStatsSubscription(fns: IOReportFunctions) -> Bool {
        // "GPU Stats" group with "GPU Performance States" subgroup — used by macmon/socpowerbuddy
        // for GPU frequency via P-state residency (channel name: GPUPH).
        guard let channels = fns.copyChannelsInGroup(
            "GPU Stats" as NSString,
            "GPU Performance States" as NSString,
            0, 0, 0
        ) else {
            Log.metrics.info("IOReport: no channels for GPU Stats / GPU Performance States")
            return false
        }

        var subbedRef: Unmanaged<CFMutableDictionary>?
        guard let sub = fns.createSubscription(nil, channels, &subbedRef, 0, nil) else {
            Log.metrics.warning("IOReport: failed to create GPU Stats subscription")
            return false
        }
        guard let subbed = subbedRef?.takeRetainedValue() else {
            Log.metrics.warning("IOReport: GPU Stats subscription created but no channels returned")
            return false
        }

        self.gpuStatsSub = sub
        self.gpuStatsSubbed = subbed

        if let initial = fns.createSamples(sub, subbed, nil)?.takeRetainedValue() {
            self.gpuStatsPrevSample = initial
        }

        Log.metrics.info("IOReport: GPU Stats subscription ready")
        return true
    }

    // MARK: - GPU Frequency Table from IORegistry

    /// Read GPU P-state frequencies from IORegistry pmgr voltage-states.
    /// On M1-M3: values are in Hz (e.g. 1398000000). On M4: values are in KHz (e.g. 1470000).
    /// Returns sorted array of frequencies in MHz.
    private static func readGPUFrequencyTable() -> [Double] {
        // Find pmgr service in IORegistry
        guard let matching = IOServiceMatching("AppleARMIODevice") else { return [] }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            // Look for the pmgr service with voltage-states9 (GPU frequency table)
            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(service, &nameBuffer)
            let name = String(cString: nameBuffer)

            if name == "pmgr" {
                if let freqs = extractGPUFrequencies(from: service) {
                    IOObjectRelease(service)
                    return freqs
                }
            }

            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        return []
    }

    /// Extract GPU frequencies from pmgr's voltage-states9 property.
    /// The property is a Data blob of pairs: (frequency: UInt32, voltage: UInt32).
    private static func extractGPUFrequencies(from service: io_service_t) -> [Double]? {
        // Try voltage-states9 first (GPU on M1-M4), then alternates seen on
        // newer chips (M5 may have shifted to another index; try a sweep).
        for key in ["voltage-states9", "voltage-states11", "voltage-states13", "voltage-states5"] {
            guard let ref = IORegistryEntryCreateCFProperty(
                service, key as CFString, kCFAllocatorDefault, 0
            ) else { continue }

            guard let data = ref.takeRetainedValue() as? Data else { continue }

            // Data is pairs of UInt32: (frequency, voltage). Collect raw freqs
            // first, then decide the unit scale from the max value across the
            // whole table — earlier code chose per-entry, which mis-classified
            // sub-GHz P-states (e.g. M4's 339 MHz reads as 339M Hz; treating
            // that as KHz produces 338,827 MHz and the sanity filter then
            // drops it, leaving the table missing every low P-state).
            let pairSize = MemoryLayout<UInt32>.size * 2
            guard data.count >= pairSize else { continue }

            var rawFreqs: [UInt32] = []
            for offset in stride(from: 0, to: data.count, by: pairSize) {
                let freqRaw = data.withUnsafeBytes { buf in
                    buf.load(fromByteOffset: offset, as: UInt32.self)
                }
                if freqRaw == 0 { continue }
                rawFreqs.append(freqRaw)
            }
            guard let maxRaw = rawFreqs.max() else { continue }

            // Pick scale once based on the table's peak value.
            // GPU max is realistically 0.5–3 GHz: Hz form > 100M, KHz form
            // > 100k, MHz form 100–5000.
            let scale: Double
            if maxRaw > 100_000_000 {
                scale = 1_000_000.0  // Hz → MHz
            } else if maxRaw > 100_000 {
                scale = 1_000.0      // KHz → MHz
            } else {
                scale = 1.0          // already MHz
            }

            let frequencies = rawFreqs
                .map { Double($0) / scale }
                .filter { $0 >= 100 && $0 <= 5000 }

            if !frequencies.isEmpty {
                // Dedupe within 1 MHz — voltage-states blobs often store
                // adjacent rail variants of the same P-state.
                let sorted = frequencies.sorted()
                var unique: [Double] = []
                for f in sorted where unique.last.map({ abs(f - $0) > 1.0 }) ?? true {
                    unique.append(f)
                }
                return unique
            }
        }

        return nil
    }

    // MARK: - Public Interface

    var isAvailable: Bool {
        gpuServiceAvailable || energyReady
    }

    var isPowerMetricsAvailable: Bool {
        energyReady
    }

    /// GPU P-state frequency table (MHz values, sorted ascending)
    var frequencyTable: [Double] {
        gpuFreqTable
    }

    /// Sample current hardware metrics.
    func sample() -> HardwareMetrics {
        // GPU utilization from IORegistry (AGXAccelerator)
        var gpuUtilization: Double = 0
        if gpuServiceAvailable && acceleratorService != 0 {
            if let properties = getServiceProperties(acceleratorService) {
                if let perfStats = properties["PerformanceStatistics"] as? [String: Any] {
                    if let deviceUtil = perfStats["Device Utilization %"] as? NSNumber {
                        gpuUtilization = deviceUtil.doubleValue / 100.0
                    }
                }
            }
        }

        guard let fns = fns else {
            return HardwareMetrics(
                gpuUtilization: min(1.0, max(0.0, gpuUtilization)),
                gpuPowerWatts: 0, cpuPowerWatts: 0, anePowerWatts: 0,
                dramPowerWatts: 0, systemPowerWatts: 0, gpuFrequencyMHz: 0,
                pStateDistribution: [],
                isAvailable: gpuServiceAvailable
            )
        }

        // --- Energy Model delta (power) ---
        var gpuPower: Double = 0
        var cpuPower: Double = 0
        var anePower: Double = 0
        var dramPower: Double = 0

        if energyReady, let sub = energySub, let subbed = energySubbed {
            let now = Date()
            if let current = fns.createSamples(sub, subbed, nil)?.takeRetainedValue() {
                if let prev = energyPrevSample, let prevTime = energyPrevTime {
                    let elapsed = now.timeIntervalSince(prevTime)
                    if elapsed > 0.01 {
                        if let delta = fns.createSamplesDelta(prev, current, nil)?.takeRetainedValue() {
                            let p = parseEnergyDelta(delta: delta, fns: fns, intervalSeconds: elapsed)
                            gpuPower = p.gpuPower
                            cpuPower = p.cpuPower
                            anePower = p.anePower
                            dramPower = p.dramPower
                        }
                    }
                }
                energyPrevSample = current
                energyPrevTime = now
            }
        }

        // --- GPU Stats delta (frequency + P-state distribution) ---
        var gpuFrequencyMHz: Double = 0
        var pStateDistribution: [GPUPStateResidency] = []

        if gpuStatsReady, let sub = gpuStatsSub, let subbed = gpuStatsSubbed {
            if let current = fns.createSamples(sub, subbed, nil)?.takeRetainedValue() {
                if let prev = gpuStatsPrevSample {
                    if let delta = fns.createSamplesDelta(prev, current, nil)?.takeRetainedValue() {
                        let result = parseGPUFrequencyDelta(delta: delta, fns: fns)
                        gpuFrequencyMHz = result.weightedAverageMHz
                        pStateDistribution = result.pStateDistribution
                    }
                }
                gpuStatsPrevSample = current
            }
        }

        let systemPower = gpuPower + cpuPower + anePower + dramPower

        return HardwareMetrics(
            gpuUtilization: min(1.0, max(0.0, gpuUtilization)),
            gpuPowerWatts: gpuPower,
            cpuPowerWatts: cpuPower,
            anePowerWatts: anePower,
            dramPowerWatts: dramPower,
            systemPowerWatts: systemPower,
            gpuFrequencyMHz: gpuFrequencyMHz,
            pStateDistribution: pStateDistribution,
            isAvailable: gpuServiceAvailable || energyReady
        )
    }

    // MARK: - Delta Parsing

    private struct ParsedPower {
        var gpuPower: Double = 0
        var cpuPower: Double = 0
        var anePower: Double = 0
        var dramPower: Double = 0
    }

    private struct GPUFrequencyResult {
        let weightedAverageMHz: Double
        let pStateDistribution: [GPUPStateResidency]
    }

    private func parseEnergyDelta(delta: CFDictionary, fns: IOReportFunctions, intervalSeconds: Double) -> ParsedPower {
        var gpuEnergy: Int64 = 0
        var cpuEnergy: Int64 = 0
        var aneEnergy: Int64 = 0
        var dramEnergy: Int64 = 0
        var sawAnyEnergy = false

        fns.iterate(delta as NSDictionary) { sample in
            let name = (fns.channelGetChannelName(sample) as String?) ?? ""
            let value = fns.simpleGetIntegerValue(sample, 0)

            if name == "GPU Energy" {
                gpuEnergy += value
                if value > 0 { sawAnyEnergy = true }
            } else if name == "ECPU" || name == "PCPU" {
                cpuEnergy += value
                if value > 0 { sawAnyEnergy = true }
            } else if name == "ANE" {
                aneEnergy += value
                if value > 0 { sawAnyEnergy = true }
            } else if name == "DRAM" {
                dramEnergy += value
                if value > 0 { sawAnyEnergy = true }
            }

            return 0
        }

        // Per-channel energy units on Apple Silicon (empirically verified
        // on M4 against asitop/macmon and confirmed by powermetrics):
        //   GPU Energy        → nanojoules  → ÷ (interval × 1e9) for W
        //   ECPU / PCPU       → millijoules → ÷ (interval × 1e3) for W
        //   ANE               → millijoules → ÷ (interval × 1e3) for W
        //   DRAM              → millijoules → ÷ (interval × 1e3) for W
        // Treating the latter three as nJ produced readings ~10⁶× too
        // small (CPU showed in microwatts instead of watts). If a future
        // chip changes units the diagnostic log + sanity check below
        // will surface it.
        let gpuDivisor = intervalSeconds * 1_000_000_000.0  // nJ → W
        let mjDivisor  = intervalSeconds * 1_000.0          // mJ → W
        let computedGpu  = Double(gpuEnergy)  / gpuDivisor
        let computedCpu  = Double(cpuEnergy)  / mjDivisor
        let computedAne  = Double(aneEnergy)  / mjDivisor
        let computedDram = Double(dramEnergy) / mjDivisor

        if !hasLoggedEnergy && sawAnyEnergy {
            hasLoggedEnergy = true
            Log.metrics.info("Energy delta (interval=\(intervalSeconds, privacy: .public)s): raw gpu=\(gpuEnergy, privacy: .public)nJ cpu=\(cpuEnergy, privacy: .public)mJ ane=\(aneEnergy, privacy: .public)mJ dram=\(dramEnergy, privacy: .public)mJ → computed gpu=\(computedGpu, privacy: .public)W cpu=\(computedCpu, privacy: .public)W ane=\(computedAne, privacy: .public)W dram=\(computedDram, privacy: .public)W")
        }

        // Sanity check: Apple Silicon SoC components never exceed ~200W
        // sustained. If we ever read above that, the unit assumption is
        // wrong for this chip and we should not pollute the leaderboard
        // with the bad value.
        let suspiciouslyHigh = 200.0
        for (name, value) in [("gpu", computedGpu), ("cpu", computedCpu), ("ane", computedAne), ("dram", computedDram)] where value > suspiciouslyHigh {
            Log.metrics.warning("Energy channel \(name, privacy: .public) computed \(value, privacy: .public)W — exceeds plausible SoC limit; unit assumption likely wrong on this chip")
        }

        return ParsedPower(
            gpuPower: computedGpu,
            cpuPower: computedCpu,
            anePower: computedAne,
            dramPower: computedDram
        )
    }

    /// Parse GPU frequency from "GPU Stats" / "GPU Performance States" delta.
    /// The GPUPH channel has state residencies for each P-state.
    /// Weighted average frequency = sum(freq[i] * residency[i]) / sum(residency[i])
    /// Also returns per-P-state residency distribution for the detail view.
    private func parseGPUFrequencyDelta(delta: CFDictionary, fns: IOReportFunctions) -> GPUFrequencyResult {
        var weightedFreqSum: Double = 0
        var totalResidency: Int64 = 0
        var stateEntries: [(frequencyMHz: Double, residencyNs: Int64)] = []
        let shouldLog = !hasLoggedGpuStats

        fns.iterate(delta as NSDictionary) { sample in
            let name = (fns.channelGetChannelName(sample) as String?) ?? ""

            // GPUPH is the GPU P-state history channel
            if name == "GPUPH" || name.hasPrefix("GPU") {
                let stateCount = fns.stateGetCount(sample)

                if shouldLog {
                    let subGroup = (fns.channelGetSubGroup(sample) as String?) ?? ""
                    var stateInfo: [String] = []
                    for i in 0..<min(stateCount, 20) {
                        if let sn = fns.stateGetNameForIndex(sample, i) as String? {
                            let r = fns.stateGetResidency(sample, i)
                            stateInfo.append("\(sn):\(r)")
                        }
                    }
                    Log.metrics.info("GPU Stats delta: name=\(name, privacy: .public) subGroup=\(subGroup, privacy: .public) states=\(stateCount) [\(stateInfo.joined(separator: ", "), privacy: .public)]")
                }

                // Each state is a P-state with a frequency.
                // State names may be frequencies ("1398") or P-state labels ("P1").
                // If labels, use gpuFreqTable to map index → MHz.
                for i in 0..<stateCount {
                    let residency = fns.stateGetResidency(sample, i)
                    guard residency > 0 else { continue }

                    var freqMHz: Double = 0

                    // Try parsing frequency from state name
                    if let stateName = fns.stateGetNameForIndex(sample, i) as String? {
                        if let parsed = self.parseFrequencyFromState(stateName) {
                            freqMHz = parsed
                        }
                    }

                    // Fall back to frequency table (index 0 = OFF/idle, skip it)
                    if freqMHz == 0 && !self.gpuFreqTable.isEmpty {
                        // State index 0 is typically OFF/idle state.
                        // P-states map to gpuFreqTable[stateIndex - 1]; if
                        // GPUPH reports more states than the table holds,
                        // saturate to the top entry rather than silently
                        // dropping the residency (which biases the weighted
                        // mean toward whatever low entries survived).
                        let tableIdx = Int(i) - 1
                        if tableIdx >= 0 {
                            let capped = min(tableIdx, self.gpuFreqTable.count - 1)
                            freqMHz = self.gpuFreqTable[capped]
                        }
                    }

                    if freqMHz > 0 {
                        weightedFreqSum += freqMHz * Double(residency)
                        totalResidency += residency
                        stateEntries.append((frequencyMHz: freqMHz, residencyNs: residency))
                    }
                }
            }

            return 0
        }

        if shouldLog {
            hasLoggedGpuStats = true
            Log.metrics.info("GPU Stats result: totalResidency=\(totalResidency) freqTable=\(self.gpuFreqTable.count) states")
        }

        let avgFreq = totalResidency > 0 ? weightedFreqSum / Double(totalResidency) : 0
        let distribution: [GPUPStateResidency] = stateEntries
            .sorted { $0.frequencyMHz < $1.frequencyMHz }
            .map { entry in
                GPUPStateResidency(
                    frequencyMHz: entry.frequencyMHz,
                    residencyNs: entry.residencyNs,
                    fraction: totalResidency > 0 ? Double(entry.residencyNs) / Double(totalResidency) : 0
                )
            }

        return GPUFrequencyResult(weightedAverageMHz: avgFreq, pStateDistribution: distribution)
    }

    /// Parse frequency in MHz from a state name.
    /// Handles formats like "1398", "DVFS:1398", "1398 MHz", "P9:1470"
    private func parseFrequencyFromState(_ stateName: String) -> Double? {
        // Skip known non-frequency names
        let lower = stateName.lowercased()
        if lower == "off" || lower == "idle" || lower.hasPrefix("p0") { return nil }

        let scanner = Scanner(string: stateName)
        scanner.charactersToBeSkipped = CharacterSet.decimalDigits.inverted
        var value: Int = 0
        while !scanner.isAtEnd {
            if scanner.scanInt(&value) && value >= 100 && value <= 5000 {
                return Double(value)
            }
        }
        return nil
    }

    // MARK: - IORegistry Helpers

    private func getServiceProperties(_ service: io_service_t) -> [String: Any]? {
        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)

        if result == KERN_SUCCESS, let props = properties?.takeRetainedValue() as? [String: Any] {
            return props
        }
        return nil
    }
}

// MARK: - GPU P-State Residency

/// Per-P-state residency from IOReport GPU Stats.
/// Shows how much time the GPU spent at each frequency level.
struct GPUPStateResidency: Sendable, Codable, Identifiable {
    let frequencyMHz: Double
    let residencyNs: Int64
    let fraction: Double  // 0.0–1.0, proportion of total residency

    var id: Double { frequencyMHz }
}

// MARK: - Hardware Metrics

/// Hardware metrics from IOKit + IOReport
struct HardwareMetrics: Sendable {
    let gpuUtilization: Double      // 0.0 - 1.0 (from AGXAccelerator IORegistry)
    let gpuPowerWatts: Double       // GPU power in watts (IOReport Energy Model)
    let cpuPowerWatts: Double       // CPU power in watts (E+P clusters)
    let anePowerWatts: Double       // Neural Engine power in watts
    let dramPowerWatts: Double      // DRAM power in watts
    let systemPowerWatts: Double    // Sum of all power components
    let gpuFrequencyMHz: Double     // Weighted average GPU frequency (IOReport GPU Stats)
    let pStateDistribution: [GPUPStateResidency]  // Per-P-state residency distribution
    let isAvailable: Bool

    static let unavailable = HardwareMetrics(
        gpuUtilization: 0,
        gpuPowerWatts: 0,
        cpuPowerWatts: 0,
        anePowerWatts: 0,
        dramPowerWatts: 0,
        systemPowerWatts: 0,
        gpuFrequencyMHz: 0,
        pStateDistribution: [],
        isAvailable: false
    )
}
