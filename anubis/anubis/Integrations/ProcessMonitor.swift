//
//  ProcessMonitor.swift
//  anubis
//
//  Universal backend process detection and monitoring.
//  Replaces the inline Ollama-only PID scanning in MetricsCollector.
//

import Foundation
import Darwin

// libproc constants not exposed to Swift
private let PROC_PIDPATHINFO_MAXSIZE: Int = 4096

/// Type of backend process
enum BackendProcessType: String, Sendable {
    case ollama
    case lmStudio = "lm_studio"
    case mlxLM = "mlx_lm"
    case vllm = "vllm"
    case localAI = "local_ai"
    case llamaServer = "llama_server"
    case custom
    case unknown
}

/// Lightweight process info for the process picker UI
struct ProcessCandidate: Identifiable, Sendable {
    let pid: pid_t
    let name: String
    let path: String
    let memoryBytes: Int64

    var id: pid_t { pid }
}

/// Information about a detected backend process
struct BackendProcessInfo: Sendable {
    let pid: pid_t
    let type: BackendProcessType
    let name: String
    let memoryBytes: Int64
    let cpuPercent: Double
}

/// Actor that detects and monitors ANY backend process (not just Ollama).
/// Uses `proc_pidpath` for detection and `proc_pidinfo` for memory metrics.
/// PID cache with configurable TTL avoids full process scan on every sample.
actor ProcessMonitor {
    // PID cache
    private var cachedBackends: [BackendProcessInfo] = []
    private var primaryBackend: BackendProcessInfo?
    private var cacheTime: Date = .distantPast
    private let cacheTTL: TimeInterval = 5.0

    // Custom process override
    private var customPID: pid_t?
    private var customName: String?
    /// When true, use single-process memory instead of tree/bundle aggregation.
    /// Set for LM Studio (heaviest child selected) and manual picker.
    private var customSingleProcess: Bool = false

    // CPU tracking for delta-based calculation
    private var previousCPUTimes: [pid_t: (user: UInt64, system: UInt64, timestamp: Date)] = [:]

    // One-shot diagnostic logging
    private var hasLoggedTreeMemory = false

    /// Detection patterns: path suffix → type mapping.
    /// LM Studio is checked BEFORE Ollama because LM Studio bundles an embedded
    /// ollama binary whose path contains both "LM Studio" and "ollama".
    private static let detectionPatterns: [(pathCheck: (String) -> Bool, type: BackendProcessType, name: String)] = [
        // LM Studio first — its embedded server paths contain "ollama"
        ({ $0.contains("LM Studio") || $0.hasSuffix("/lms") },
         .lmStudio, "LM Studio"),
        ({ $0.hasSuffix("/ollama") || $0.contains("/ollama.app/") || ($0.contains("Ollama.app") && $0.hasSuffix("Ollama")) },
         .ollama, "Ollama"),
        ({ $0.contains("mlx_lm") || $0.contains("mlx-lm") || $0.hasSuffix("/mlx_lm.server") },
         .mlxLM, "mlx-lm"),
        ({ $0.hasSuffix("/vllm") || $0.contains("vllm.entrypoints") },
         .vllm, "vLLM"),
        ({ $0.hasSuffix("/local-ai") || $0.contains("LocalAI") },
         .localAI, "LocalAI"),
        ({ $0.hasSuffix("/llama-server") || ($0.hasSuffix("/server") && $0.contains("llama")) },
         .llamaServer, "llama.cpp"),
    ]

    /// Python-based backends detected via command-line arguments
    private static let pythonPatterns: [(argCheck: (String) -> Bool, type: BackendProcessType, name: String)] = [
        ({ $0.contains("mlx_lm") || $0.contains("mlx-lm") }, .mlxLM, "mlx-lm"),
        ({ $0.contains("vllm") }, .vllm, "vLLM"),
        ({ $0.contains("tabbyAPI") || $0.contains("tabby_api") }, .unknown, "TabbyAPI"),
    ]

    // MARK: - Public API

    /// Detect all running backend processes
    func detectBackends() -> [BackendProcessInfo] {
        let now = Date()
        if now.timeIntervalSince(cacheTime) < cacheTTL && !cachedBackends.isEmpty {
            // Validate cached PIDs are still alive
            let alive = cachedBackends.filter { getProcessMemory(pid: $0.pid) > 0 }
            if !alive.isEmpty {
                return alive
            }
        }

        cachedBackends = scanForBackends()
        cacheTime = now
        return cachedBackends
    }

    /// Find the primary (preferred) backend process
    func findPrimaryBackend(preferredType: BackendProcessType? = nil) -> BackendProcessInfo? {
        // Custom/port-detected process override takes absolute priority
        if let pid = customPID {
            let memory = customSingleProcess
                ? getProcessMemory(pid: pid)
                : getProcessTreeMemory(rootPID: pid)
            if memory > 0 {
                let cpu = calculateCPUPercent(pid: pid)
                let info = BackendProcessInfo(
                    pid: pid,
                    type: .custom,
                    name: customName ?? "Custom",
                    memoryBytes: memory,
                    cpuPercent: cpu
                )
                primaryBackend = info
                return info
            } else {
                // Process died — clear the override
                customPID = nil
                customName = nil
                customSingleProcess = false
            }
        }

        let backends = detectBackends()

        if let preferred = preferredType,
           let match = backends.first(where: { $0.type == preferred }) {
            primaryBackend = match
            return match
        }

        // Default priority: Ollama > LM Studio > llama-server > mlx-lm > vLLM > LocalAI
        let priority: [BackendProcessType] = [.ollama, .lmStudio, .llamaServer, .mlxLM, .vllm, .localAI]
        for type in priority {
            if let match = backends.first(where: { $0.type == type }) {
                primaryBackend = match
                return match
            }
        }

        primaryBackend = backends.first
        return backends.first
    }

    /// Set a custom process to monitor (overrides auto-detection)
    func setCustomProcess(pid: pid_t, name: String) {
        customPID = pid
        customName = name
        customSingleProcess = true // User explicitly selected this process
        // Clear cache so next findPrimaryBackend uses the custom process
        cachedBackends = []
        cacheTime = .distantPast
    }

    /// Clear the custom process override (return to auto-detection)
    func clearCustomProcess() {
        customPID = nil
        customName = nil
        customSingleProcess = false
    }

    /// Whether a custom process is currently set
    func hasCustomProcess() -> Bool {
        customPID != nil
    }

    // MARK: - Port-Based Detection

    /// Find the process listening on a given TCP port.
    /// Uses `lsof` for reliable port→PID resolution. Called once per benchmark start, not per-poll.
    /// Returns the PID and identifies the backend type from its path and command line.
    func findProcessOnPort(_ port: UInt16) -> BackendProcessInfo? {
        guard let pid = lsofListeningPID(port: port) else { return nil }

        let memory = getProcessTreeMemory(rootPID: pid)
        let cpu = calculateCPUPercent(pid: pid)

        // Identify type from path
        var pathBuffer = [CChar](repeating: 0, count: PROC_PIDPATHINFO_MAXSIZE)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(cString: pathBuffer) : ""
        let execName = (path as NSString).lastPathComponent

        // Check path-based patterns first
        for pattern in Self.detectionPatterns {
            if pattern.pathCheck(path) {
                return BackendProcessInfo(
                    pid: pid, type: pattern.type, name: pattern.name,
                    memoryBytes: memory, cpuPercent: cpu
                )
            }
        }

        // Check if it's a Python process — inspect command-line args
        if execName.hasPrefix("python") || execName.hasPrefix("Python") {
            if let (type, name) = identifyPythonProcess(pid: pid) {
                return BackendProcessInfo(
                    pid: pid, type: type, name: name,
                    memoryBytes: memory, cpuPercent: cpu
                )
            }
        }

        // Unknown server — use executable name
        return BackendProcessInfo(
            pid: pid, type: .unknown, name: execName.isEmpty ? "Port \(port)" : execName,
            memoryBytes: memory, cpuPercent: cpu
        )
    }

    /// Auto-detect the backend by port, set it as the monitored process, and return info.
    /// Call this when a benchmark starts to lock onto the actual server process.
    ///
    /// For LM Studio (Electron app), instead of tracking the port-listening process,
    /// finds the Node child with the highest memory — that's the one holding the model.
    func autoDetectByPort(_ port: UInt16) -> BackendProcessInfo? {
        guard let info = findProcessOnPort(port) else { return nil }

        // For LM Studio, find the heaviest process in the bundle + its descendants
        if info.type == .lmStudio,
           let heaviest = findHeaviestRelatedProcess(forPID: info.pid) {
            customPID = heaviest.pid
            customName = info.name
            customSingleProcess = true
            hasLoggedTreeMemory = false
            cachedBackends = []
            cacheTime = .distantPast
            let cpu = calculateCPUPercent(pid: heaviest.pid)
            return BackendProcessInfo(
                pid: heaviest.pid, type: .lmStudio, name: info.name,
                memoryBytes: heaviest.memory, cpuPercent: cpu
            )
        }

        customPID = info.pid
        customName = info.name
        customSingleProcess = false // Use tree memory for Ollama etc.
        hasLoggedTreeMemory = false
        cachedBackends = []
        cacheTime = .distantPast
        return info
    }

    // MARK: - Process Tree Memory

    /// Sum RSS of a process and all related processes for accurate memory accounting.
    ///
    /// Uses two strategies:
    /// 1. **App bundle aggregation** — if the process lives inside a `.app` bundle
    ///    (e.g. LM Studio.app, Ollama.app), find ALL processes whose path shares that
    ///    bundle prefix. This catches Electron's scattered Node helpers, embedded servers,
    ///    and any subprocess regardless of parent-child relationship.
    /// 2. **Recursive tree walk** — for non-bundled processes (CLI tools, Python servers),
    ///    walk the full descendant tree via parent PID matching.
    func getProcessTreeMemory(rootPID: pid_t) -> Int64 {
        // Get the root process path to decide strategy
        var pathBuffer = [CChar](repeating: 0, count: PROC_PIDPATHINFO_MAXSIZE)
        let pathLength = proc_pidpath(rootPID, &pathBuffer, UInt32(pathBuffer.count))
        let rootPath = pathLength > 0 ? String(cString: pathBuffer) : ""

        // Check if inside a .app bundle → use bundle aggregation
        if let bundlePrefix = extractAppBundlePrefix(from: rootPath) {
            let (total, count) = aggregateMemoryForBundle(prefix: bundlePrefix)
            if !hasLoggedTreeMemory {
                hasLoggedTreeMemory = true
                print("ProcessMonitor: bundle aggregation for \"\(bundlePrefix)\" → \(count) processes, \(total / 1_048_576) MB")
            }
            return total
        }

        // Otherwise use recursive descendant walk
        let (total, count) = aggregateMemoryForDescendants(rootPID: rootPID)
        if !hasLoggedTreeMemory {
            hasLoggedTreeMemory = true
            print("ProcessMonitor: descendant walk from PID \(rootPID) (\((rootPath as NSString).lastPathComponent)) → \(count) processes, \(total / 1_048_576) MB")
        }
        return total
    }

    /// Extract the .app bundle prefix from a path.
    /// e.g. "/Applications/LM Studio.app/Contents/MacOS/node" → "/Applications/LM Studio.app/"
    ///
    /// Excludes `.app` paths inside `.framework` bundles (e.g. Python.framework/.../Python.app)
    /// which are framework-internal wrappers, not real application bundles.
    private func extractAppBundlePrefix(from path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        let prefix = String(path[...range.upperBound])
        // Reject if .app is nested inside a .framework — not a real app bundle
        if prefix.contains(".framework/") { return nil }
        return prefix
    }

    /// Find the process with the highest `phys_footprint` related to the given PID's app bundle.
    ///
    /// Searches both within the `.app` bundle AND all descendant processes spawned by
    /// bundle members. This catches model servers that live outside the bundle
    /// (e.g. `~/.cache/lm-studio/bin/llama-server`) as long as they were spawned by
    /// an app bundle process.
    private func findHeaviestRelatedProcess(forPID pid: pid_t) -> (pid: pid_t, memory: Int64)? {
        var pathBuffer = [CChar](repeating: 0, count: PROC_PIDPATHINFO_MAXSIZE)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }

        let path = String(cString: pathBuffer)
        guard let prefix = extractAppBundlePrefix(from: path) else { return nil }

        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return nil }

        let pidCount = bufferSize / Int32(MemoryLayout<pid_t>.size)
        var pids = [pid_t](repeating: 0, count: Int(pidCount))
        let actualSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        guard actualSize > 0 else { return nil }

        let actualCount = Int(actualSize) / MemoryLayout<pid_t>.size

        // Pass 1: identify all bundle PIDs and build parent→children map
        var bundlePIDs: Set<pid_t> = []
        var childrenOf: [pid_t: [pid_t]] = [:]

        for i in 0..<actualCount {
            let p = pids[i]
            guard p > 0 else { continue }

            // Check if in bundle
            var buf = [CChar](repeating: 0, count: PROC_PIDPATHINFO_MAXSIZE)
            let len = proc_pidpath(p, &buf, UInt32(buf.count))
            if len > 0 {
                let pPath = String(cString: buf)
                if pPath.hasPrefix(prefix) {
                    bundlePIDs.insert(p)
                }
            }

            // Record parent→child relationship
            var bsdInfo = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            let result = proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &bsdInfo, bsdSize)
            if result == bsdSize {
                let ppid = pid_t(bsdInfo.pbi_ppid)
                childrenOf[ppid, default: []].append(p)
            }
        }

        // Pass 2: BFS from all bundle PIDs to find all related descendants
        var relatedPIDs = bundlePIDs
        var queue = Array(bundlePIDs)

        while !queue.isEmpty {
            let current = queue.removeFirst()
            for child in childrenOf[current] ?? [] {
                if !relatedPIDs.contains(child) {
                    relatedPIDs.insert(child)
                    queue.append(child)
                }
            }
        }

        // Pass 3: find the heaviest related process
        var heaviestPID: pid_t = pid
        var heaviestMemory: Int64 = 0

        for p in relatedPIDs {
            let mem = getProcessMemory(pid: p)
            if mem > heaviestMemory {
                heaviestMemory = mem
                heaviestPID = p
            }
        }

        if heaviestMemory > 0 {
            let inBundle = bundlePIDs.contains(heaviestPID) ? "bundle" : "descendant"
            print("ProcessMonitor: heaviest related to \"\(prefix)\" → PID \(heaviestPID) (\(inBundle)), \(heaviestMemory / 1_048_576) MB (\(relatedPIDs.count) related processes)")
            return (heaviestPID, heaviestMemory)
        }
        return nil
    }

    /// Find ALL processes whose executable path starts with the given .app bundle prefix
    /// and sum their memory. Handles Electron apps (multiple Node helpers), bundled servers, etc.
    /// Returns (totalBytes, processCount).
    private func aggregateMemoryForBundle(prefix: String) -> (Int64, Int) {
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return (0, 0) }

        let pidCount = bufferSize / Int32(MemoryLayout<pid_t>.size)
        var pids = [pid_t](repeating: 0, count: Int(pidCount))
        let actualSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        guard actualSize > 0 else { return (0, 0) }

        let actualCount = Int(actualSize) / MemoryLayout<pid_t>.size
        var total: Int64 = 0
        var count = 0

        for i in 0..<actualCount {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var buf = [CChar](repeating: 0, count: PROC_PIDPATHINFO_MAXSIZE)
            let len = proc_pidpath(pid, &buf, UInt32(buf.count))
            guard len > 0 else { continue }

            let path = String(cString: buf)
            if path.hasPrefix(prefix) {
                total += getProcessMemory(pid: pid)
                count += 1
            }
        }

        return (total, count)
    }

    /// Walk the full descendant tree (recursive) from a root PID and sum RSS.
    /// Used for non-bundled processes like CLI tools and Python servers.
    /// Returns (totalBytes, processCount).
    private func aggregateMemoryForDescendants(rootPID: pid_t) -> (Int64, Int) {
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return (getProcessMemory(pid: rootPID), 1) }

        let pidCount = bufferSize / Int32(MemoryLayout<pid_t>.size)
        var pids = [pid_t](repeating: 0, count: Int(pidCount))
        let actualSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        guard actualSize > 0 else { return (getProcessMemory(pid: rootPID), 1) }

        let actualCount = Int(actualSize) / MemoryLayout<pid_t>.size

        // Build parent → children map
        var childrenOf: [pid_t: [pid_t]] = [:]
        for i in 0..<actualCount {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var bsdInfo = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, bsdSize)
            guard result == bsdSize else { continue }

            let ppid = pid_t(bsdInfo.pbi_ppid)
            childrenOf[ppid, default: []].append(pid)
        }

        // BFS from root to collect all descendants
        var total: Int64 = getProcessMemory(pid: rootPID)
        var queue = childrenOf[rootPID] ?? []
        var visited: Set<pid_t> = [rootPID]

        while !queue.isEmpty {
            let pid = queue.removeFirst()
            guard !visited.contains(pid) else { continue }
            visited.insert(pid)
            total += getProcessMemory(pid: pid)

            if let grandchildren = childrenOf[pid] {
                queue.append(contentsOf: grandchildren)
            }
        }

        return (total, visited.count)
    }

    // MARK: - Python Command-Line Detection

    /// Read a process's command-line arguments via sysctl KERN_PROCARGS2.
    /// Returns the joined argv string for pattern matching.
    private func getProcessArgs(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0

        // First call to get buffer size
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        // KERN_PROCARGS2 format: [int32 argc][exec_path\0][padding\0...][argv[0]\0][argv[1]\0]...
        guard size > MemoryLayout<Int32>.size else { return nil }

        // Skip argc
        var offset = MemoryLayout<Int32>.size

        // Skip exec path
        while offset < size && buffer[offset] != 0 { offset += 1 }
        // Skip null padding between exec path and argv
        while offset < size && buffer[offset] == 0 { offset += 1 }

        // Read remaining as argv joined by spaces (enough for pattern matching)
        let argsData = Data(buffer[offset..<size])
        // Replace null separators with spaces
        let argsString = argsData.map { $0 == 0 ? UInt8(0x20) : $0 }
        return String(bytes: argsString, encoding: .utf8)?.trimmingCharacters(in: .whitespaces)
    }

    /// Identify a Python process by its command-line arguments
    private func identifyPythonProcess(pid: pid_t) -> (BackendProcessType, String)? {
        guard let args = getProcessArgs(pid: pid) else { return nil }

        for pattern in Self.pythonPatterns {
            if pattern.argCheck(args) {
                return (pattern.type, pattern.name)
            }
        }
        return nil
    }

    // MARK: - lsof Port Resolution

    /// Use lsof to find which PID is listening on a TCP port
    private func lsofListeningPID(port: UInt16) -> pid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-i", "TCP:\(port)", "-sTCP:LISTEN", "-t", "-n", "-P"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }

        // lsof -t returns one PID per line; take the first
        if let firstLine = output.components(separatedBy: "\n").first,
           let pid = Int32(firstLine) {
            return pid
        }
        return nil
    }

    /// List candidate processes for the picker UI.
    /// Returns processes with >50MB RSS, sorted by memory descending.
    func listCandidateProcesses() -> [ProcessCandidate] {
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return [] }

        let pidCount = bufferSize / Int32(MemoryLayout<pid_t>.size)
        var pids = [pid_t](repeating: 0, count: Int(pidCount))
        let actualSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        guard actualSize > 0 else { return [] }

        let actualCount = Int(actualSize) / MemoryLayout<pid_t>.size
        let minMemory: Int64 = 50 * 1024 * 1024 // 50 MB threshold
        let myPID = getpid()
        var candidates: [ProcessCandidate] = []

        for i in 0..<actualCount {
            let pid = pids[i]
            guard pid > 0 && pid != myPID else { continue }

            let memory = getProcessMemory(pid: pid)
            guard memory >= minMemory else { continue }

            var pathBuffer = [CChar](repeating: 0, count: PROC_PIDPATHINFO_MAXSIZE)
            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard pathLength > 0 else { continue }

            let path = String(cString: pathBuffer)
            let name = (path as NSString).lastPathComponent

            candidates.append(ProcessCandidate(
                pid: pid,
                name: name,
                path: path,
                memoryBytes: memory
            ))
        }

        return candidates.sorted { $0.memoryBytes > $1.memoryBytes }
    }

    /// Get current metrics for a specific process
    func getProcessMetrics(pid: pid_t) -> BackendProcessInfo? {
        let memory = getProcessMemory(pid: pid)
        guard memory > 0 else { return nil }

        let cpu = calculateCPUPercent(pid: pid)

        // Find the cached info for this PID to get type/name
        if let cached = cachedBackends.first(where: { $0.pid == pid }) {
            return BackendProcessInfo(
                pid: pid,
                type: cached.type,
                name: cached.name,
                memoryBytes: memory,
                cpuPercent: cpu
            )
        }

        return BackendProcessInfo(
            pid: pid,
            type: .unknown,
            name: "Unknown",
            memoryBytes: memory,
            cpuPercent: cpu
        )
    }

    /// Reset CPU tracking state
    func resetCPUTracking() {
        previousCPUTimes.removeAll()
    }

    // MARK: - Private

    private func scanForBackends() -> [BackendProcessInfo] {
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return [] }

        let pidCount = bufferSize / Int32(MemoryLayout<pid_t>.size)
        var pids = [pid_t](repeating: 0, count: Int(pidCount))

        let actualSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        guard actualSize > 0 else { return [] }

        let actualCount = Int(actualSize) / MemoryLayout<pid_t>.size
        var found: [BackendProcessInfo] = []
        var seenTypes: Set<BackendProcessType> = []
        var pythonPIDs: [pid_t] = [] // Collect for cmdline inspection

        for i in 0..<actualCount {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var pathBuffer = [CChar](repeating: 0, count: PROC_PIDPATHINFO_MAXSIZE)
            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard pathLength > 0 else { continue }

            let path = String(cString: pathBuffer)
            let execName = (path as NSString).lastPathComponent

            // Check path-based patterns
            var matched = false
            for pattern in Self.detectionPatterns {
                if pattern.pathCheck(path) && !seenTypes.contains(pattern.type) {
                    let memory = getProcessTreeMemory(rootPID: pid)
                    let cpu = calculateCPUPercent(pid: pid)
                    found.append(BackendProcessInfo(
                        pid: pid,
                        type: pattern.type,
                        name: pattern.name,
                        memoryBytes: memory,
                        cpuPercent: cpu
                    ))
                    seenTypes.insert(pattern.type)
                    matched = true
                    break
                }
            }

            // Collect Python processes for cmdline inspection
            if !matched && (execName.hasPrefix("python") || execName.hasPrefix("Python")) {
                pythonPIDs.append(pid)
            }
        }

        // Check Python processes via command-line args (more expensive, done second)
        for pid in pythonPIDs {
            if let (type, name) = identifyPythonProcess(pid: pid),
               !seenTypes.contains(type) {
                let memory = getProcessTreeMemory(rootPID: pid)
                let cpu = calculateCPUPercent(pid: pid)
                found.append(BackendProcessInfo(
                    pid: pid, type: type, name: name,
                    memoryBytes: memory, cpuPercent: cpu
                ))
                seenTypes.insert(type)
            }
        }

        return found
    }

    /// Get process memory using `phys_footprint` (matches Activity Monitor).
    /// Unlike `pti_resident_size`, this includes Metal/GPU buffer allocations
    /// which is critical for MLX and other GPU-accelerated inference backends.
    private func getProcessMemory(pid: pid_t) -> Int64 {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rusagePtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rusagePtr)
            }
        }
        if result == 0 {
            return Int64(usage.ri_phys_footprint)
        }
        // Fallback to pti_resident_size if rusage fails
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let pidResult = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        return pidResult == size ? Int64(info.pti_resident_size) : 0
    }

    private func calculateCPUPercent(pid: pid_t) -> Double {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard result == size else { return 0 }

        let now = Date()
        let currentUser = UInt64(info.pti_total_user)
        let currentSystem = UInt64(info.pti_total_system)

        defer {
            previousCPUTimes[pid] = (currentUser, currentSystem, now)
        }

        guard let previous = previousCPUTimes[pid] else {
            return 0
        }

        let elapsed = now.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else { return 0 }

        let deltaUser = currentUser - previous.user
        let deltaSystem = currentSystem - previous.system
        let totalDeltaNs = Double(deltaUser + deltaSystem)

        // Convert from Mach absolute time units to seconds, then to percentage
        // pti_total_user/system are in Mach time units (nanoseconds on Apple Silicon)
        let cpuSeconds = totalDeltaNs / 1_000_000_000.0
        let cpuPercent = (cpuSeconds / elapsed) * 100.0

        return min(cpuPercent, 100.0 * Double(ProcessInfo.processInfo.activeProcessorCount))
    }
}
