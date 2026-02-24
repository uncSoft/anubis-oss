//
//  LeaderboardService.swift
//  anubis
//
//  Actor-based service for uploading benchmarks to the community leaderboard.
//

import Foundation
import CryptoKit
import IOKit

// MARK: - API Types

struct LeaderboardSubmission: Codable {
    // Identity
    let machineId: String
    let displayName: String
    let appVersion: String

    // Session
    let modelId: String
    let modelName: String
    let backend: String
    let startedAt: String
    let endedAt: String?
    let prompt: String
    let status: String

    // Tokens
    let totalTokens: Int?
    let promptTokens: Int?
    let completionTokens: Int?

    // Performance
    let tokensPerSecond: Double?
    let totalDuration: Double?
    let promptEvalDuration: Double?
    let evalDuration: Double?

    // Latency
    let timeToFirstToken: Double?
    let loadDuration: Double?
    let contextLength: Int?
    let peakMemoryBytes: Int64?
    let avgTokenLatencyMs: Double?

    // Power
    let avgGpuPowerWatts: Double?
    let peakGpuPowerWatts: Double?
    let avgSystemPowerWatts: Double?
    let peakSystemPowerWatts: Double?
    let avgGpuFrequencyMhz: Double?
    let peakGpuFrequencyMhz: Double?
    let avgWattsPerToken: Double?

    // Process
    let backendProcessName: String?

    // Chip info (flattened)
    let chipName: String?
    let chipCoreCount: Int?
    let chipPCores: Int?
    let chipECores: Int?
    let chipGpuCores: Int?
    let chipNeuralCores: Int?
    let chipMemoryGb: Int?
    let chipBandwidthGbs: Double?
    let chipMacModel: String?
    let chipMacModelId: String?

    enum CodingKeys: String, CodingKey {
        case machineId = "machine_id"
        case displayName = "display_name"
        case appVersion = "app_version"
        case modelId = "model_id"
        case modelName = "model_name"
        case backend
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case prompt
        case status
        case totalTokens = "total_tokens"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case tokensPerSecond = "tokens_per_second"
        case totalDuration = "total_duration"
        case promptEvalDuration = "prompt_eval_duration"
        case evalDuration = "eval_duration"
        case timeToFirstToken = "time_to_first_token"
        case loadDuration = "load_duration"
        case contextLength = "context_length"
        case peakMemoryBytes = "peak_memory_bytes"
        case avgTokenLatencyMs = "avg_token_latency_ms"
        case avgGpuPowerWatts = "avg_gpu_power_watts"
        case peakGpuPowerWatts = "peak_gpu_power_watts"
        case avgSystemPowerWatts = "avg_system_power_watts"
        case peakSystemPowerWatts = "peak_system_power_watts"
        case avgGpuFrequencyMhz = "avg_gpu_frequency_mhz"
        case peakGpuFrequencyMhz = "peak_gpu_frequency_mhz"
        case avgWattsPerToken = "avg_watts_per_token"
        case backendProcessName = "backend_process_name"
        case chipName = "chip_name"
        case chipCoreCount = "chip_core_count"
        case chipPCores = "chip_p_cores"
        case chipECores = "chip_e_cores"
        case chipGpuCores = "chip_gpu_cores"
        case chipNeuralCores = "chip_neural_cores"
        case chipMemoryGb = "chip_memory_gb"
        case chipBandwidthGbs = "chip_bandwidth_gbs"
        case chipMacModel = "chip_mac_model"
        case chipMacModelId = "chip_mac_model_id"
    }
}

struct SubmitResponse: Codable {
    let success: Bool
    let id: Int?
    let message: String?
    let error: String?
}

struct LeaderboardEntry: Codable, Identifiable {
    let id: Int
    let displayName: String
    let modelName: String
    let backend: String
    let tokensPerSecond: Double?
    let timeToFirstToken: Double?
    let totalTokens: Int?
    let completionTokens: Int?
    let avgGpuPowerWatts: Double?
    let avgSystemPowerWatts: Double?
    let avgWattsPerToken: Double?
    let avgGpuFrequencyMhz: Double?
    let chipName: String?
    let chipGpuCores: Int?
    let chipMemoryGb: Int?
    let chipMacModel: String?
    let backendProcessName: String?
    let submittedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case modelName = "model_name"
        case backend
        case tokensPerSecond = "tokens_per_second"
        case timeToFirstToken = "time_to_first_token"
        case totalTokens = "total_tokens"
        case completionTokens = "completion_tokens"
        case avgGpuPowerWatts = "avg_gpu_power_watts"
        case avgSystemPowerWatts = "avg_system_power_watts"
        case avgWattsPerToken = "avg_watts_per_token"
        case avgGpuFrequencyMhz = "avg_gpu_frequency_mhz"
        case chipName = "chip_name"
        case chipGpuCores = "chip_gpu_cores"
        case chipMemoryGb = "chip_memory_gb"
        case chipMacModel = "chip_mac_model"
        case backendProcessName = "backend_process_name"
        case submittedAt = "submitted_at"
    }
}

struct LeaderboardResponse: Codable {
    let count: Int
    let entries: [LeaderboardEntry]
}

// MARK: - Service

actor LeaderboardService {
    private let baseURL: URL
    private let session: URLSession
    private let hmacSecret: String

    private static let iso8601: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    init() {
        self.baseURL = Constants.URLs.leaderboardAPI
        self.hmacSecret = Secrets.leaderboardHMACSecret

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Submit

    func submit(session benchmarkSession: BenchmarkSession, displayName: String) async throws -> SubmitResponse {
        guard benchmarkSession.status == .completed else {
            throw AnubisError.leaderboardError(reason: "Only completed benchmarks can be uploaded")
        }

        let trimmedName = String(displayName.prefix(Constants.Leaderboard.maxDisplayNameLength))
        guard !trimmedName.isEmpty else {
            throw AnubisError.leaderboardError(reason: "Display name cannot be empty")
        }

        let chip = benchmarkSession.chipInfo ?? ChipInfo.current

        let submission = LeaderboardSubmission(
            machineId: Self.obfuscatedMachineId(),
            displayName: trimmedName,
            appVersion: Self.appVersion,
            modelId: benchmarkSession.modelId,
            modelName: benchmarkSession.modelName,
            backend: benchmarkSession.backend,
            startedAt: Self.iso8601.string(from: benchmarkSession.startedAt),
            endedAt: benchmarkSession.endedAt.map { Self.iso8601.string(from: $0) },
            prompt: benchmarkSession.prompt,
            status: benchmarkSession.status.rawValue,
            totalTokens: benchmarkSession.totalTokens,
            promptTokens: benchmarkSession.promptTokens,
            completionTokens: benchmarkSession.completionTokens,
            tokensPerSecond: benchmarkSession.tokensPerSecond,
            totalDuration: benchmarkSession.totalDuration,
            promptEvalDuration: benchmarkSession.promptEvalDuration,
            evalDuration: benchmarkSession.evalDuration,
            timeToFirstToken: benchmarkSession.timeToFirstToken,
            loadDuration: benchmarkSession.loadDuration,
            contextLength: benchmarkSession.contextLength,
            peakMemoryBytes: benchmarkSession.peakMemoryBytes,
            avgTokenLatencyMs: benchmarkSession.averageTokenLatencyMs,
            avgGpuPowerWatts: benchmarkSession.avgGpuPowerWatts,
            peakGpuPowerWatts: benchmarkSession.peakGpuPowerWatts,
            avgSystemPowerWatts: benchmarkSession.avgSystemPowerWatts,
            peakSystemPowerWatts: benchmarkSession.peakSystemPowerWatts,
            avgGpuFrequencyMhz: benchmarkSession.avgGpuFrequencyMHz,
            peakGpuFrequencyMhz: benchmarkSession.peakGpuFrequencyMHz,
            avgWattsPerToken: benchmarkSession.avgWattsPerToken,
            backendProcessName: benchmarkSession.backendProcessName,
            chipName: chip.name,
            chipCoreCount: chip.coreCount,
            chipPCores: chip.performanceCores,
            chipECores: chip.efficiencyCores,
            chipGpuCores: chip.gpuCores,
            chipNeuralCores: chip.neuralEngineCores,
            chipMemoryGb: chip.unifiedMemoryGB,
            chipBandwidthGbs: chip.memoryBandwidthGBs,
            chipMacModel: chip.macModel,
            chipMacModelId: chip.macModelIdentifier
        )

        let bodyData = try JSONEncoder().encode(submission)
        guard let bodyString = String(data: bodyData, encoding: .utf8) else {
            throw AnubisError.leaderboardError(reason: "Failed to encode submission")
        }

        // HMAC signing
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let signatureInput = timestamp + bodyString
        let key = SymmetricKey(data: Data(hmacSecret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(signatureInput.utf8), using: key)
        let signatureHex = signature.map { String(format: "%02x", $0) }.joined()

        // Build request
        let url = baseURL.appendingPathComponent("submit.php")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(signatureHex, forHTTPHeaderField: "X-Anubis-Signature")
        request.setValue(timestamp, forHTTPHeaderField: "X-Anubis-Timestamp")
        request.httpBody = bodyData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnubisError.leaderboardError(reason: "Invalid server response")
        }

        let decoded = try JSONDecoder().decode(SubmitResponse.self, from: data)

        if httpResponse.statusCode == 429 {
            throw AnubisError.leaderboardError(reason: decoded.error ?? "Rate limit exceeded. Try again later.")
        }

        if httpResponse.statusCode != 200 {
            throw AnubisError.leaderboardError(reason: decoded.error ?? "Server error (\(httpResponse.statusCode))")
        }

        if !decoded.success {
            throw AnubisError.leaderboardError(reason: decoded.error ?? "Upload failed")
        }

        return decoded
    }

    // MARK: - Fetch Leaderboard

    func fetchLeaderboard(limit: Int = 100) async throws -> [LeaderboardEntry] {
        let url = baseURL.appendingPathComponent("leaderboard.php")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AnubisError.leaderboardError(reason: "Failed to fetch leaderboard")
        }

        let decoded = try JSONDecoder().decode(LeaderboardResponse.self, from: data)
        return decoded.entries
    }

    // MARK: - Machine ID

    /// Returns a one-way hashed machine identifier (SHA256 of IOPlatformUUID + app-specific salt).
    static func obfuscatedMachineId() -> String {
        let salt = "com.uncsoft.anubis.leaderboard.2026"
        let uuid = platformUUID() ?? storedFallbackUUID()
        let input = uuid + salt
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let cfValue = IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String else {
            return nil
        }

        return cfValue
    }

    private static func storedFallbackUUID() -> String {
        let key = "anubis.leaderboard.fallbackUUID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newUUID = UUID().uuidString
        UserDefaults.standard.set(newUUID, forKey: key)
        return newUUID
    }

    // MARK: - App Version

    static var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
