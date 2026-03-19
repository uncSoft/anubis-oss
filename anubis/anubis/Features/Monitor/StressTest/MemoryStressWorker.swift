//
//  MemoryStressWorker.swift
//  anubis
//

import Foundation
import Darwin.Mach
import QuartzCore

enum MemoryPressureLevel: String, CaseIterable, Identifiable {
    case light = "Light (25%)"
    case moderate = "Moderate (50%)"
    case heavy = "Heavy (75%)"

    var id: String { rawValue }

    /// Fraction of free memory to allocate
    var fractionOfFree: Double {
        switch self {
        case .light:    return 0.25
        case .moderate: return 0.50
        case .heavy:    return 0.75
        }
    }

    /// Number of concurrent streaming threads
    var threadCount: Int {
        switch self {
        case .light:    return 2
        case .moderate: return 4
        case .heavy:    return 8
        }
    }
}

/// Memory bandwidth stress test.
///
/// Allocates a working set then continuously streams through it with memcpy,
/// saturating the memory bus. Reports measured bandwidth in GB/s which can be
/// compared against the chip's theoretical maximum (e.g. M4: 120 GB/s).
final class MemoryStressWorker {
    private var allocations: [UnsafeMutableRawPointer] = []
    private(set) var isRunning = false
    private(set) var allocatedBytes: Int64 = 0
    private(set) var bandwidthGBs: Double = 0
    var pressureLevel: MemoryPressureLevel = .moderate

    private let chunkSize = 256 * 1024 * 1024  // 256 MB per chunk
    private var streamingThreads: [Thread] = []
    private var bandwidthLock = NSLock()
    private var totalBytesTransferred: Int64 = 0
    private var lastBandwidthTime = CACurrentMediaTime()

    /// Callback for bandwidth updates (~1/sec)
    var onBandwidthUpdate: ((Double) -> Void)?

    func start() {
        stop()
        isRunning = true

        let freeBytes = Self.freeMemoryBytes()
        let maxAlloc = Int64(Double(freeBytes) * pressureLevel.fractionOfFree)
        // Only allocate full-size chunks — avoids runt last chunk that causes OOB
        let fullChunksToAlloc = Int(maxAlloc) / chunkSize

        // Allocate and dirty memory on a background thread, then start streaming
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Phase 1: Allocate full-size chunks only
            for _ in 0..<fullChunksToAlloc {
                guard self.isRunning else { break }
                guard let ptr = malloc(self.chunkSize) else { break }
                memset(ptr, 0xAB, self.chunkSize)
                self.allocations.append(ptr)
                self.allocatedBytes = Int64(self.allocations.count * self.chunkSize)
            }

            // Need at least 2 chunks for src/dst pairs
            guard self.isRunning, self.allocations.count >= 2 else { return }

            // Snapshot the array — immutable from here, safe for threads to read
            let chunks = self.allocations
            let perChunkSize = self.chunkSize

            // Phase 2: Stream — multiple threads do memcpy sweeps across chunks
            self.lastBandwidthTime = CACurrentMediaTime()
            self.totalBytesTransferred = 0

            let threadCount = self.pressureLevel.threadCount
            for i in 0..<threadCount {
                let thread = Thread { [weak self] in
                    self?.streamLoop(chunks: chunks, perChunkSize: perChunkSize, threadIndex: i, threadCount: threadCount)
                }
                thread.qualityOfService = .userInitiated
                thread.name = "MemStress-\(i)"
                self.streamingThreads.append(thread)
                thread.start()
            }

            // Bandwidth measurement loop
            while self.isRunning {
                Thread.sleep(forTimeInterval: 1.0)
                guard self.isRunning else { break }
                let now = CACurrentMediaTime()
                self.bandwidthLock.lock()
                let bytes = self.totalBytesTransferred
                self.totalBytesTransferred = 0
                self.bandwidthLock.unlock()

                let elapsed = now - self.lastBandwidthTime
                self.lastBandwidthTime = now
                if elapsed > 0 {
                    let gbps = Double(bytes) / elapsed / 1e9
                    self.bandwidthGBs = gbps
                    self.onBandwidthUpdate?(gbps)
                }
            }
        }
    }

    /// Each thread sweeps through chunks, doing memcpy between src/dst pairs.
    /// `chunks` and `perChunkSize` are captured by value — safe to read from any thread.
    private func streamLoop(chunks: [UnsafeMutableRawPointer], perChunkSize: Int, threadIndex: Int, threadCount: Int) {
        let count = chunks.count
        guard count >= 2 else { return }

        // Each thread starts at a different offset to spread bus load
        var srcIdx = threadIndex % count
        var dstIdx = (threadIndex + count / 2) % count
        if dstIdx == srcIdx { dstIdx = (srcIdx + 1) % count }

        // 64 KB strides to defeat L2 prefetcher
        let strideSize = 64 * 1024

        while isRunning {
            let src = chunks[srcIdx]
            let dst = chunks[dstIdx]

            var offset = 0
            while offset < perChunkSize && isRunning {
                let copyLen = min(strideSize, perChunkSize - offset)
                memcpy(dst + offset, src + offset, copyLen)
                offset += copyLen
            }

            bandwidthLock.lock()
            totalBytesTransferred += Int64(perChunkSize) * 2  // read + write
            bandwidthLock.unlock()

            // Rotate to next chunk pair
            srcIdx = (srcIdx + 1) % count
            dstIdx = (dstIdx + 1) % count
            if dstIdx == srcIdx { dstIdx = (srcIdx + 1) % count }
        }
    }

    func stop() {
        isRunning = false
        // Wait for threads to exit
        for thread in streamingThreads {
            thread.cancel()
        }
        if !streamingThreads.isEmpty {
            Thread.sleep(forTimeInterval: 0.05)
        }
        streamingThreads.removeAll()

        for ptr in allocations {
            free(ptr)
        }
        allocations.removeAll()
        allocatedBytes = 0
        bandwidthGBs = 0
        totalBytesTransferred = 0
    }

    /// Returns free memory in bytes (free + inactive pages)
    static func freeMemoryBytes() -> Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 4 * 1024 * 1024 * 1024 }
        let pageSize = Int64(vm_kernel_page_size)
        return (Int64(stats.free_count) + Int64(stats.inactive_count)) * pageSize
    }
}
