//
//  CPUStressWorker.swift
//  anubis
//

import Foundation

enum CPUStressScope: String, CaseIterable, Identifiable {
    case allCores = "All Cores"
    case pCoresOnly = "P-Cores Only"
    case eCoresOnly = "E-Cores Only"
    case singleCore = "Single Core"

    var id: String { rawValue }

    func coreCount(chip: ChipInfo) -> Int {
        switch self {
        case .allCores: return chip.coreCount
        case .pCoresOnly: return chip.performanceCores
        case .eCoresOnly: return chip.efficiencyCores
        case .singleCore: return 1
        }
    }
}

/// Spawns `yes > /dev/null` processes to stress CPU cores.
final class CPUStressWorker {
    private var processes: [Process] = []
    private(set) var isRunning = false
    private(set) var coreCount = 0

    func start(scope: CPUStressScope) {
        stop()
        let chip = ChipInfo.current
        coreCount = scope.coreCount(chip: chip)
        isRunning = true

        for _ in 0..<coreCount {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                processes.append(process)
            } catch {
                // If we can't spawn, just continue with fewer cores
            }
        }
    }

    func stop() {
        for process in processes {
            if process.isRunning {
                process.terminate()
            }
        }
        processes.removeAll()
        isRunning = false
        coreCount = 0
    }
}
