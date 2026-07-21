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
    case omlx
    case mtplx
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
    /// Sampled CPU% — 0 on first sighting (needs a baseline), real value on
    /// subsequent refreshes. Picker uses this to surface the active worker.
    let cpuPercent: Double
    /// Optional discriminator for generic interpreters (e.g. "llmworker.js"
    /// for a node process running LM Studio's inference worker, "mlx_lm.server"
    /// for a python process running mlx-lm). Lets the picker show
    /// "node (llmworker.js)" instead of five identical-looking "node" rows.
    let subtitle: String?

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

    /// When non-nil, customPID was set by autoDetectByPort (a "soft" pin
    /// that should periodically re-evaluate) rather than by the user picking
    /// from the menu (a "hard" pin that stays put). LM Studio's inference
    /// worker doesn't reach its true memory/heaviest-process status until
    /// the model finishes loading — which may happen during the first rep,
    /// not before. Re-evaluating every few seconds lets us converge to the
    /// real worker without depending on rep boundaries.
    private var softPinPort: UInt16?
    private var lastSoftPinCheck: Date = .distantPast
    private let softPinCheckInterval: TimeInterval = 2.0

    // CPU tracking for delta-based calculation
    private var previousCPUTimes: [pid_t: (user: UInt64, system: UInt64, timestamp: Date)] = [:]

    // One-shot diagnostic logging
    private var hasLoggedTreeMemory = false

    /// Detection patterns: path suffix → type mapping.
    /// LM Studio is checked BEFORE Ollama because LM Studio bundles an embedded
    /// ollama binary whose path contains both "LM Studio" and "ollama".
    private static let detectionPatterns: [(pathCheck: (String) -> Bool, type: BackendProcessType, name: String)] = [
        // LM Studio first — its embedded server paths contain "ollama".
        // /.lmstudio/ matches the per-user runtime cache where the actual
        // inference worker (node + llmworker.js) lives — outside the .app
        // bundle, sometimes reparented to launchd.
        ({ $0.contains("LM Studio") || $0.hasSuffix("/lms") || $0.contains("/.lmstudio/") },
         .lmStudio, "LM Studio"),
        ({ $0.hasSuffix("/ollama") || $0.contains("/ollama.app/") || ($0.contains("Ollama.app") && $0.hasSuffix("Ollama")) },
         .ollama, "Ollama"),
        // oMLX (github.com/jundot/omlx) — its own menubar app + python server.
        // Checked before mlx-lm; "omlx" never matches the mlx_lm/mlx-lm patterns
        // below, but keep it ahead so the more specific label always wins.
        ({ $0.lowercased().contains("omlx") },
         .omlx, "oMLX"),
        ({ $0.lowercased().contains("mtplx") },
         .mtplx, "MTPLX"),
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
        ({ $0.lowercased().contains("omlx") }, .omlx, "oMLX"),
        ({ $0.lowercased().contains("mtplx") }, .mtplx, "MTPLX"),
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
        // Self-healing soft pin: if customPID was set via autoDetectByPort
        // (model may not have been loaded yet), re-evaluate every couple of
        // seconds and switch to a heavier related process if one has
        // emerged. No-op for hard pins (manual picker) and for sessions
        // that never ran autoDetectByPort.
        if let port = softPinPort,
           Date().timeIntervalSince(lastSoftPinCheck) >= softPinCheckInterval {
            lastSoftPinCheck = Date()
            _ = refreshSoftPin(port: port)
        }

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
                // If this was a soft pin (auto-detected via port), don't
                // fall through to the priority-based default. That path
                // happily returns the first Ollama process it sees, which
                // is exactly the "switched LM Studio model, got Ollama
                // attribution" bug. Return nil and let the next sample's
                // soft-pin refresh re-discover the right worker.
                if softPinPort != nil {
                    return nil
                }
            }
        }

        let backends = detectBackends()

        if let preferred = preferredType,
           let match = backends.first(where: { $0.type == preferred }) {
            primaryBackend = match
            return match
        }

        // Default priority: Ollama > LM Studio > llama-server > MTPLX > oMLX > mlx-lm > vLLM > LocalAI
        let priority: [BackendProcessType] = [.ollama, .lmStudio, .llamaServer, .mtplx, .omlx, .mlxLM, .vllm, .localAI]
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
        // User picked manually — disable soft-pin re-evaluation so we don't
        // overwrite their choice from under them.
        softPinPort = nil
        // Clear cache so next findPrimaryBackend uses the custom process
        cachedBackends = []
        cacheTime = .distantPast
    }

    /// Clear the custom process override (return to auto-detection)
    func clearCustomProcess() {
        customPID = nil
        customName = nil
        customSingleProcess = false
        softPinPort = nil
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
        softPinPort = port
        lastSoftPinCheck = Date()
        return applyAutoDetectResult(info: info)
    }

    /// Re-run auto-detect for a port without rotating the soft-pin timestamp
    /// management — used by the in-place self-healing path inside
    /// findPrimaryBackend.
    @discardableResult
    private func refreshSoftPin(port: UInt16) -> BackendProcessInfo? {
        guard let info = findProcessOnPort(port) else {
            // Port stopped listening (server restarting, mid-switch, etc.).
            // Hold the existing pin rather than clearing — losing it would
            // make the metrics loop fall through to priority defaults and
            // mis-attribute to whichever backend happens to be running.
            return nil
        }
        return applyAutoDetectResult(info: info)
    }

    /// Apply an auto-detection result: pick the heaviest related worker
    /// (LM Studio specifically), set customPID, return the info.
    private func applyAutoDetectResult(info: BackendProcessInfo) -> BackendProcessInfo {
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

        // LM Studio's inference worker lives in the per-user runtime cache
        // (~/.lmstudio/.internal/utils/node), NOT inside the .app bundle, and
        // may be reparented to launchd — so we treat any process under that
        // tree as bundle-related when the bundle prefix is LM Studio.app.
        let lmStudioRuntimeMarker = prefix.contains("LM Studio.app") ? "/.lmstudio/" : nil

        // Pass 1: identify all bundle PIDs and build parent→children map
        var bundlePIDs: Set<pid_t> = []
        var childrenOf: [pid_t: [pid_t]] = [:]

        for i in 0..<actualCount {
            let p = pids[i]
            guard p > 0 else { continue }

            // Check if in bundle (or in the LM Studio per-user runtime cache)
            var buf = [CChar](repeating: 0, count: PROC_PIDPATHINFO_MAXSIZE)
            let len = proc_pidpath(p, &buf, UInt32(buf.count))
            if len > 0 {
                let pPath = String(cString: buf)
                if pPath.hasPrefix(prefix) {
                    bundlePIDs.insert(p)
                } else if let marker = lmStudioRuntimeMarker, pPath.contains(marker) {
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

    /// Read a process's argv as discrete tokens (preserves entries that contain
    /// spaces — unlike `getProcessArgs`, which joins with spaces for substring
    /// matching). Returns nil if `sysctl(KERN_PROCARGS2)` can't read the process
    /// (typically: process exited, or owned by a different user without privilege).
    private func getProcessArgv(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        guard size > MemoryLayout<Int32>.size else { return nil }

        var argc: Int32 = 0
        _ = withUnsafeMutableBytes(of: &argc) { argcBytes in
            buffer.withUnsafeBytes { bufBytes in
                argcBytes.copyBytes(from: bufBytes.prefix(MemoryLayout<Int32>.size))
            }
        }
        guard argc > 0 else { return nil }

        var offset = MemoryLayout<Int32>.size
        // Skip the exec path (NUL-terminated)
        while offset < size && buffer[offset] != 0 { offset += 1 }
        // Skip the run of padding NULs before argv[0]
        while offset < size && buffer[offset] == 0 { offset += 1 }

        var argv: [String] = []
        var current = offset
        while argv.count < Int(argc) && current < size {
            var end = current
            while end < size && buffer[end] != 0 { end += 1 }
            if let token = String(bytes: buffer[current..<end], encoding: .utf8) {
                argv.append(token)
            }
            current = end + 1
        }
        return argv
    }

    /// Best-effort discovery of the model file backing a mmap-based inference server
    /// (llama.cpp `llama-server`, ds4-server, any GGUF-based service). Scans the
    /// process's argv for `-m` / `--model` / `--model-path` followed by a `.gguf`
    /// or `.safetensors` path, then `stat`s it. Returns the file size in bytes, or
    /// nil if no path is found or the file isn't readable.
    ///
    /// This is the cmdline fallback for the on-disk-model-size compensation in
    /// `BenchmarkViewModel.fetchModelMemory()`. Without it, `phys_footprint`
    /// silently under-reports memory by the size of the model for every
    /// llama.cpp-derived backend (see GitHub issue #29).
    func discoverModelFileSize(pid: pid_t) -> Int64? {
        guard let argv = getProcessArgv(pid: pid), argv.count > 1 else { return nil }

        let flags: Set<String> = ["-m", "--model", "--model-path"]
        let modelExtensions = [".gguf", ".safetensors"]
        let fm = FileManager.default

        var i = 0
        while i < argv.count - 1 {
            if flags.contains(argv[i]) {
                let path = argv[i + 1]
                let lower = path.lowercased()
                if modelExtensions.contains(where: { lower.hasSuffix($0) }),
                   let attrs = try? fm.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? Int64,
                   size > 0 {
                    return size
                }
            }
            i += 1
        }
        return nil
    }

    /// Cmdline-derived model-file-size lookup for the currently-monitored backend.
    /// Returns nil if no backend is being monitored or no model path is discoverable.
    func discoverCurrentBackendModelFileSize() -> Int64? {
        let pid: pid_t? = customPID ?? primaryBackend?.pid
        guard let pid else { return nil }
        return discoverModelFileSize(pid: pid)
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
    /// Each refresh samples CPU% — the first call returns 0% (no baseline);
    /// subsequent calls return the real value. The picker polls this on a
    /// timer so the user can spot the active worker by its CPU spike.
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
            let cpu = calculateCPUPercent(pid: pid)
            let subtitle = inferProcessSubtitle(pid: pid, execName: name, path: path)

            candidates.append(ProcessCandidate(
                pid: pid,
                name: name,
                path: path,
                memoryBytes: memory,
                cpuPercent: cpu,
                subtitle: subtitle
            ))
        }

        return candidates.sorted { $0.memoryBytes > $1.memoryBytes }
    }

    /// Discriminator for interpreter processes (node, python) whose exec name
    /// alone tells the user nothing. We peek at argv and surface a single
    /// recognisable token — e.g. "llmworker.js" for LM Studio's inference
    /// worker — so the picker shows "node (llmworker.js)" instead of five
    /// identical "node" rows.
    private func inferProcessSubtitle(pid: pid_t, execName: String, path: String) -> String? {
        let isNode = execName == "node" || path.hasSuffix("/node")
        let isPython = execName.hasPrefix("python") || execName.hasPrefix("Python")
        guard isNode || isPython else { return nil }
        guard let args = getProcessArgs(pid: pid) else { return nil }

        if isNode {
            // Prefer the LAST .js token — for LM Studio that's the worker file
            // passed as the actual script arg (an earlier copy appears inside
            // the inline require() string that opens argv[2]).
            let tokens = args.split(separator: " ", omittingEmptySubsequences: true)
            if let jsArg = tokens.reversed().first(where: { $0.hasSuffix(".js") }) {
                return (String(jsArg) as NSString).lastPathComponent
            }
            return nil
        }

        // Python — reuse the existing backend patterns
        for pattern in Self.pythonPatterns {
            if pattern.argCheck(args) { return pattern.name }
        }
        return nil
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
