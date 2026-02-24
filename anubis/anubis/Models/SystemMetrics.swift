//
//  SystemMetrics.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation
import IOKit

// MARK: - Per-Core Types

enum CoreType: String, Codable, Sendable {
    case performance, efficiency
}

struct CoreUtilization: Sendable, Codable {
    let coreIndex: Int
    let coreType: CoreType
    let utilization: Double  // 0.0–1.0
}

/// Hardware and system metrics captured during benchmarking
struct SystemMetrics: Sendable, Codable {
    /// Timestamp of the measurement
    let timestamp: Date

    /// GPU utilization (0.0 - 1.0)
    let gpuUtilization: Double

    /// CPU utilization (0.0 - 1.0)
    let cpuUtilization: Double

    /// Memory currently used in bytes
    let memoryUsedBytes: Int64

    /// Total system memory in bytes
    let memoryTotalBytes: Int64

    /// Current thermal state
    let thermalState: ThermalState

    // MARK: - Power Metrics (from IOReport)

    /// GPU power consumption in watts
    let gpuPowerWatts: Double?

    /// CPU power consumption in watts (E+P clusters)
    let cpuPowerWatts: Double?

    /// Neural Engine power consumption in watts
    let anePowerWatts: Double?

    /// DRAM power consumption in watts
    let dramPowerWatts: Double?

    /// Total system-on-chip power in watts
    let systemPowerWatts: Double?

    /// GPU frequency in MHz (weighted average from CLPC)
    let gpuFrequencyMHz: Double?

    // MARK: - Backend Process Metrics (from ProcessMonitor)

    /// Backend process resident memory in bytes
    let backendProcessMemoryBytes: Int64?

    /// Backend process CPU usage percentage
    let backendProcessCPUPercent: Double?

    /// Backend process name (e.g. "Ollama", "LM Studio")
    let backendProcessName: String?

    // MARK: - Per-Core Utilization (live-only, not persisted)

    /// Per-core CPU utilization breakdown (nil when not collected)
    let perCoreUtilization: [CoreUtilization]?

    /// GPU P-state frequency distribution (nil when not available)
    let gpuPStateDistribution: [GPUPStateResidency]?

    // MARK: - Backward-compatible convenience init (original 6 parameters)

    init(
        timestamp: Date,
        gpuUtilization: Double,
        cpuUtilization: Double,
        memoryUsedBytes: Int64,
        memoryTotalBytes: Int64,
        thermalState: ThermalState
    ) {
        self.timestamp = timestamp
        self.gpuUtilization = gpuUtilization
        self.cpuUtilization = cpuUtilization
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.thermalState = thermalState
        self.gpuPowerWatts = nil
        self.cpuPowerWatts = nil
        self.anePowerWatts = nil
        self.dramPowerWatts = nil
        self.systemPowerWatts = nil
        self.gpuFrequencyMHz = nil
        self.backendProcessMemoryBytes = nil
        self.backendProcessCPUPercent = nil
        self.backendProcessName = nil
        self.perCoreUtilization = nil
        self.gpuPStateDistribution = nil
    }

    // MARK: - Full init

    init(
        timestamp: Date,
        gpuUtilization: Double,
        cpuUtilization: Double,
        memoryUsedBytes: Int64,
        memoryTotalBytes: Int64,
        thermalState: ThermalState,
        gpuPowerWatts: Double?,
        cpuPowerWatts: Double?,
        anePowerWatts: Double?,
        dramPowerWatts: Double?,
        systemPowerWatts: Double?,
        gpuFrequencyMHz: Double?,
        backendProcessMemoryBytes: Int64?,
        backendProcessCPUPercent: Double?,
        backendProcessName: String?,
        perCoreUtilization: [CoreUtilization]? = nil,
        gpuPStateDistribution: [GPUPStateResidency]? = nil
    ) {
        self.timestamp = timestamp
        self.gpuUtilization = gpuUtilization
        self.cpuUtilization = cpuUtilization
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.thermalState = thermalState
        self.gpuPowerWatts = gpuPowerWatts
        self.cpuPowerWatts = cpuPowerWatts
        self.anePowerWatts = anePowerWatts
        self.dramPowerWatts = dramPowerWatts
        self.systemPowerWatts = systemPowerWatts
        self.gpuFrequencyMHz = gpuFrequencyMHz
        self.backendProcessMemoryBytes = backendProcessMemoryBytes
        self.backendProcessCPUPercent = backendProcessCPUPercent
        self.backendProcessName = backendProcessName
        self.perCoreUtilization = perCoreUtilization
        self.gpuPStateDistribution = gpuPStateDistribution
    }

    // MARK: - Computed Properties

    /// Memory utilization as a percentage (0.0 - 1.0)
    var memoryUtilization: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return Double(memoryUsedBytes) / Double(memoryTotalBytes)
    }

    /// Formatted memory usage for display
    var formattedMemoryUsage: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        let used = formatter.string(fromByteCount: memoryUsedBytes)
        let total = formatter.string(fromByteCount: memoryTotalBytes)
        return "\(used) / \(total)"
    }

    /// Total power consumption (sum of all components)
    var totalPowerWatts: Double? {
        systemPowerWatts
    }
}

/// Thermal state mapping from ProcessInfo.ThermalState
enum ThermalState: Int, Codable, Sendable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    init(from processInfoState: ProcessInfo.ThermalState) {
        switch processInfoState {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    var displayName: String {
        switch self {
        case .nominal: return "Normal"
        case .fair: return "Fair"
        case .serious: return "Throttled"
        case .critical: return "Critical"
        }
    }

    var color: String {
        switch self {
        case .nominal: return "anubisSuccess"
        case .fair: return "anubisWarning"
        case .serious: return "anubisError"
        case .critical: return "anubisError"
        }
    }
}

/// Chip information for the current Mac
struct ChipInfo: Sendable, Codable {
    let name: String
    let coreCount: Int
    let performanceCores: Int
    let efficiencyCores: Int
    let gpuCores: Int
    let neuralEngineCores: Int
    let unifiedMemoryGB: Int
    let memoryBandwidthGBs: Double

    /// Mac model marketing name (e.g. "MacBook Pro (14-inch, M4, Nov 2024)")
    /// Optional for backward compatibility with sessions stored before this field existed.
    let macModel: String?

    /// Raw hw.model identifier (e.g. "Mac16,1")
    let macModelIdentifier: String?

    /// Detect real chip info using sysctl and IOKit
    static var current: ChipInfo {
        let brandString = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let pCores = sysctlInt64("hw.perflevel0.logicalcpu").flatMap { Int($0) } ?? 0
        let eCores = sysctlInt64("hw.perflevel1.logicalcpu").flatMap { Int($0) } ?? 0
        let totalCores = pCores + eCores
        let gpuCores = detectGPUCoreCount()
        let memGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))

        // Lookup ANE cores and memory bandwidth from chip model
        let (aneCores, bandwidth) = chipLookup(name: brandString, memGB: memGB)

        return ChipInfo(
            name: brandString,
            coreCount: totalCores > 0 ? totalCores : ProcessInfo.processInfo.activeProcessorCount,
            performanceCores: pCores,
            efficiencyCores: eCores,
            gpuCores: gpuCores,
            neuralEngineCores: aneCores,
            unifiedMemoryGB: memGB,
            memoryBandwidthGBs: bandwidth,
            macModel: macModelName,
            macModelIdentifier: Self.macModelIdentifier
        )
    }

    /// Mac model marketing name (e.g. "MacBook Pro (14-inch, Nov 2024)")
    /// Uses hw.model identifier → TelemetryDeck/AppleModelNames lookup for specific names.
    /// Falls back to IORegistry product-name (generic, e.g. "MacBook Pro") then hw.model raw.
    static var macModelName: String {
        // Primary: hw.model → lookup table for specific model name
        if let modelId = sysctlString("hw.model"),
           let readable = macModelNameTable[modelId] {
            return readable
        }
        // Secondary: IORegistry product-name (generic marketing name)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            if let cfVal = IORegistryEntryCreateCFProperty(service, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data,
               let name = String(data: cfVal, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters),
               !name.isEmpty {
                return name
            }
        }
        return sysctlString("hw.model") ?? "Mac"
    }

    /// hw.model identifier (e.g. "Mac16,1") — exposed for reports/data export
    static var macModelIdentifier: String {
        sysctlString("hw.model") ?? "Unknown"
    }

    // Model identifier → marketing name lookup table
    // Source: https://github.com/TelemetryDeck/AppleModelNames
    // cSpell:disable
    private static let macModelNameTable: [String: String] = [
        // Apple Silicon — Mac (new identifier format)
        "Mac13,1": "Mac Studio (M1 Max, 2022)",
        "Mac13,2": "Mac Studio (M1 Ultra, 2022)",
        "Mac14,2": "MacBook Air (M2, 2022)",
        "Mac14,3": "Mac mini (M2, 2023)",
        "Mac14,5": "MacBook Pro (14-inch, M2 Max, 2023)",
        "Mac14,6": "MacBook Pro (16-inch, M2 Max, 2023)",
        "Mac14,7": "MacBook Pro (13-inch, M2, 2022)",
        "Mac14,8": "Mac Pro (M2 Ultra, 2023)",
        "Mac14,9": "MacBook Pro (14-inch, M2 Pro, 2023)",
        "Mac14,10": "MacBook Pro (16-inch, M2 Pro, 2023)",
        "Mac14,12": "Mac mini (M2 Pro, 2023)",
        "Mac14,13": "Mac Studio (M2 Max, 2023)",
        "Mac14,14": "Mac Studio (M2 Ultra, 2023)",
        "Mac14,15": "MacBook Air (15-inch, M2, 2023)",
        "Mac15,3": "MacBook Pro (14-inch, M3, Nov 2023)",
        "Mac15,4": "iMac (24-inch, M3, 2023)",
        "Mac15,5": "iMac (24-inch, M3, 2023)",
        "Mac15,6": "MacBook Pro (14-inch, M3 Pro, Nov 2023)",
        "Mac15,7": "MacBook Pro (16-inch, M3 Pro, Nov 2023)",
        "Mac15,8": "MacBook Pro (14-inch, M3 Max, Nov 2023)",
        "Mac15,9": "MacBook Pro (16-inch, M3 Max, Nov 2023)",
        "Mac15,10": "MacBook Pro (14-inch, M3 Pro, Nov 2023)",
        "Mac15,11": "MacBook Pro (16-inch, M3 Max, Nov 2023)",
        "Mac15,12": "MacBook Air (13-inch, M3, 2024)",
        "Mac15,13": "MacBook Air (15-inch, M3, 2024)",
        "Mac15,14": "Mac Studio (M3 Ultra, 2025)",
        "Mac16,1": "MacBook Pro (14-inch, M4, Nov 2024)",
        "Mac16,2": "iMac (24-inch, M4, 2024)",
        "Mac16,3": "iMac (24-inch, M4, 2024)",
        "Mac16,5": "MacBook Pro (16-inch, M4 Max, Nov 2024)",
        "Mac16,6": "MacBook Pro (14-inch, M4 Pro, Nov 2024)",
        "Mac16,7": "MacBook Pro (16-inch, M4 Pro, Nov 2024)",
        "Mac16,8": "MacBook Pro (14-inch, M4 Max, Nov 2024)",
        "Mac16,9": "Mac Studio (M4 Max, 2025)",
        "Mac16,10": "Mac mini (M4, 2024)",
        "Mac16,11": "Mac mini (M4 Pro, 2024)",
        "Mac16,12": "MacBook Air (13-inch, M4, 2025)",
        "Mac16,13": "MacBook Air (15-inch, M4, 2025)",
        "Mac17,2": "MacBook Pro (14-inch, M5, 2025)",
        // Apple Silicon — legacy identifier format
        "MacBookAir10,1": "MacBook Air (M1, 2020)",
        "MacBookPro17,1": "MacBook Pro (13-inch, M1, 2020)",
        "MacBookPro18,1": "MacBook Pro (16-inch, M1 Max, 2021)",
        "MacBookPro18,2": "MacBook Pro (16-inch, M1 Max, 2021)",
        "MacBookPro18,3": "MacBook Pro (14-inch, M1 Pro, 2021)",
        "MacBookPro18,4": "MacBook Pro (14-inch, M1 Max, 2021)",
        "Macmini9,1": "Mac mini (M1, 2020)",
        "iMac21,1": "iMac (24-inch, M1, 2021)",
        "iMac21,2": "iMac (24-inch, M1, 2021)",
        // Virtual machines
        "VirtualMac2,1": "Apple Virtual Machine",
        // Recent Intel Macs (for completeness)
        "MacBookPro15,1": "MacBook Pro (15-inch, 2018)",
        "MacBookPro15,2": "MacBook Pro (13-inch, 2018)",
        "MacBookPro15,3": "MacBook Pro (15-inch, 2019)",
        "MacBookPro15,4": "MacBook Pro (13-inch, 2019)",
        "MacBookPro16,1": "MacBook Pro (16-inch, 2019)",
        "MacBookPro16,2": "MacBook Pro (13-inch, 2020)",
        "MacBookPro16,3": "MacBook Pro (13-inch, 2020)",
        "MacBookAir8,1": "MacBook Air (2018)",
        "MacBookAir8,2": "MacBook Air (2019)",
        "MacBookAir9,1": "MacBook Air (2020)",
        "Macmini8,1": "Mac mini (2018)",
        "MacPro7,1": "Mac Pro (2019)",
        "iMac19,1": "iMac (27-inch, 2019)",
        "iMac19,2": "iMac (21.5-inch, 2019)",
        "iMac20,1": "iMac (27-inch, 2020)",
        "iMac20,2": "iMac (27-inch, 2020)",
        "iMacPro1,1": "iMac Pro (2017)",
    ]
    // cSpell:enable

    /// Summary string for display (e.g. "Apple M2 Pro · 6P+4E · 19 GPU")
    var summary: String {
        var parts: [String] = [name]
        if performanceCores > 0 || efficiencyCores > 0 {
            parts.append("\(performanceCores)P+\(efficiencyCores)E")
        }
        if gpuCores > 0 {
            parts.append("\(gpuCores) GPU")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Private Helpers

    private static func sysctlString(_ key: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt64(_ key: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func detectGPUCoreCount() -> Int {
        // Try AGXAccelerator first, then fallback service names
        let serviceNames = ["AGXAccelerator", "AGXAcceleratorG13", "AGXAcceleratorG14", "AGXAcceleratorG15"]
        for serviceName in serviceNames {
            guard let matching = IOServiceMatching(serviceName) else { continue }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }

            let service = IOIteratorNext(iterator)
            guard service != 0 else { continue }
            defer { IOObjectRelease(service) }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = properties?.takeRetainedValue() as? [String: Any] else { continue }

            if let count = dict["gpu-core-count"] as? Int {
                return count
            }
            // Try reading from data blob
            if let data = dict["gpu-core-count"] as? Data, data.count >= 4 {
                return Int(data.withUnsafeBytes { $0.load(as: UInt32.self) })
            }
        }
        return 0
    }

    /// Lookup ANE core count and memory bandwidth based on chip name
    private static func chipLookup(name: String, memGB: Int) -> (aneCores: Int, bandwidthGBs: Double) {
        let lower = name.lowercased()

        // M4 family (2024)
        if lower.contains("m4 ultra") { return (32, 800) }
        if lower.contains("m4 max") { return (16, 546) }
        if lower.contains("m4 pro") { return (16, 273) }
        if lower.contains("m4") { return (16, 120) }

        // M3 family (2023)
        if lower.contains("m3 ultra") { return (32, 800) }
        if lower.contains("m3 max") { return (16, 400) }
        if lower.contains("m3 pro") { return (16, 150) }
        if lower.contains("m3") { return (16, 100) }

        // M2 family (2022-2023)
        if lower.contains("m2 ultra") { return (32, 800) }
        if lower.contains("m2 max") { return (16, 400) }
        if lower.contains("m2 pro") { return (16, 200) }
        if lower.contains("m2") { return (16, 100) }

        // M1 family (2020-2022)
        if lower.contains("m1 ultra") { return (32, 800) }
        if lower.contains("m1 max") { return (16, 400) }
        if lower.contains("m1 pro") { return (16, 200) }
        if lower.contains("m1") { return (16, 68.25) }

        // Fallback
        return (16, 100)
    }
}

