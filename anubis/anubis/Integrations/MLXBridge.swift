//
//  MLXBridge.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation

/// Bridge to mlx-swift for direct Metal-accelerated inference
///
/// MLX provides optimal performance on Apple Silicon by leveraging
/// the unified memory architecture and Metal compute shaders.
actor MLXBridge: InferenceBackend {
    // MARK: - Properties

    let backendType: InferenceBackendType = .mlx

    /// Directory paths to scan for MLX models
    private var modelDirectories: [URL]

    /// Cache of discovered models
    private var cachedModels: [ModelInfo] = []
    private var lastScanDate: Date?

    /// Model cache expiration interval
    private let cacheExpiration: TimeInterval = 60

    // MARK: - Initialization

    init(modelDirectories: [URL] = MLXBridge.defaultModelDirectories) {
        self.modelDirectories = modelDirectories
    }

    /// Default directories where MLX models are typically stored
    ///
    /// In a sandboxed app, `homeDirectoryForCurrentUser` resolves to the
    /// sandbox container — not the real user home. Model scanning therefore
    /// only works for paths the user explicitly grants access to via
    /// `NSOpenPanel` or drag-and-drop. The defaults below are kept as
    /// fallbacks for non-sandboxed (development) builds.
    static var defaultModelDirectories: [URL] {
        // In a sandboxed environment these paths won't resolve to the real
        // home directory, so we return an empty list and rely on the user
        // adding directories via the UI (addModelDirectory).
        let dominated = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        guard !dominated else { return [] }

        var directories: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        directories.append(home.appendingPathComponent(".cache/huggingface/hub"))
        directories.append(home.appendingPathComponent("models/mlx"))
        return directories
    }

    // MARK: - InferenceBackend

    var isAvailable: Bool {
        get async {
            // Check if MLX framework is available
            // In a full implementation, this would check for mlx-swift availability
            return checkMLXAvailability()
        }
    }

    func checkHealth() async -> BackendHealth {
        if checkMLXAvailability() {
            return .healthy(version: "0.10+")
        } else {
            return .unhealthy(error: "MLX framework not available")
        }
    }

    func listModels() async throws -> [ModelInfo] {
        // Return cached models if still valid
        if let lastScan = lastScanDate,
           Date().timeIntervalSince(lastScan) < cacheExpiration,
           !cachedModels.isEmpty {
            return cachedModels
        }

        // Scan directories for MLX models
        var models: [ModelInfo] = []

        for directory in modelDirectories {
            let foundModels = scanDirectory(directory)
            models.append(contentsOf: foundModels)
        }

        cachedModels = models
        lastScanDate = Date()

        return models
    }

    func generate(request: InferenceRequest) -> AsyncThrowingStream<InferenceChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await streamGenerate(request: request, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Model Management

    /// Add a directory to scan for models
    func addModelDirectory(_ directory: URL) {
        if !modelDirectories.contains(directory) {
            modelDirectories.append(directory)
            lastScanDate = nil // Invalidate cache
        }
    }

    /// Force a rescan of model directories
    func refreshModels() async throws -> [ModelInfo] {
        lastScanDate = nil
        return try await listModels()
    }

    // MARK: - Private Methods

    private func checkMLXAvailability() -> Bool {
        // Check if running on Apple Silicon
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    private func scanDirectory(_ directory: URL) -> [ModelInfo] {
        var models: [ModelInfo] = []
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: directory.path) else {
            return models
        }

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            )

            for item in contents {
                if let modelInfo = parseModelDirectory(item) {
                    models.append(modelInfo)
                }
            }
        } catch {
            // Log but don't throw - some directories may not be accessible
        }

        return models
    }

    private func parseModelDirectory(_ directory: URL) -> ModelInfo? {
        let fileManager = FileManager.default

        // Check for MLX model indicators
        let configPath = directory.appendingPathComponent("config.json")
        let weightsPath = directory.appendingPathComponent("model.safetensors")
        let mlxWeightsPath = directory.appendingPathComponent("weights.npz")

        guard fileManager.fileExists(atPath: configPath.path) &&
              (fileManager.fileExists(atPath: weightsPath.path) ||
               fileManager.fileExists(atPath: mlxWeightsPath.path)) else {
            return nil
        }

        // Parse config.json for model metadata
        var modelType: String?
        var parameterCount: Double?

        if let configData = fileManager.contents(atPath: configPath.path),
           let config = try? JSONDecoder().decode(MLXConfigFile.self, from: configData) {
            modelType = config.modelType
            // Estimate parameters from architecture
            if let hidden = config.hiddenSize, let layers = config.numHiddenLayers {
                // Rough approximation: 12 * hidden^2 * layers for transformer
                let params = Double(12 * hidden * hidden * layers)
                parameterCount = params / 1_000_000_000 // Convert to billions
            }
        }

        // Calculate total size
        var totalSize: Int64 = 0
        if let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) {
            while let fileURL = enumerator.nextObject() as? URL {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(size)
                }
            }
        }

        let modifiedAt = try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        let quantization = Self.detectMLXQuantization(directory.lastPathComponent)

        return ModelInfo(
            id: "mlx:\(directory.lastPathComponent)",
            name: directory.lastPathComponent,
            family: modelType,
            parameterCount: parameterCount,
            quantization: quantization,
            modelFormat: .mlx,
            sizeBytes: totalSize,
            contextLength: nil,
            backend: .mlx,
            openAIConfigId: nil,
            path: directory.path,
            modifiedAt: modifiedAt
        )
    }

    /// Detect quantization from MLX model directory name
    private static func detectMLXQuantization(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("mxfp4") { return "MXFP4" }
        if lower.contains("4bit") || lower.contains("4-bit") { return "4-bit" }
        if lower.contains("8bit") || lower.contains("8-bit") { return "8-bit" }
        if lower.contains("3bit") || lower.contains("3-bit") { return "3-bit" }
        if lower.contains("fp16") || lower.contains("f16") { return "FP16" }
        if lower.contains("bf16") { return "BF16" }
        return "FP16" // Default for MLX models without explicit quantization
    }

    private func streamGenerate(
        request: InferenceRequest,
        continuation: AsyncThrowingStream<InferenceChunk, Error>.Continuation
    ) async throws {
        // Verify model exists
        let models = try await listModels()
        guard let model = models.first(where: { $0.id == request.model || $0.name == request.model }) else {
            throw AnubisError.modelNotFound(modelId: request.model)
        }

        guard let modelPath = model.path else {
            throw AnubisError.modelLoadFailed(modelId: request.model, reason: "Model path not available")
        }

        // In a full implementation, this would:
        // 1. Load the model using mlx-swift
        // 2. Tokenize the prompt
        // 3. Run inference with streaming output
        // 4. Detokenize and yield chunks

        // For now, provide a placeholder implementation that can be replaced
        // when mlx-swift integration is complete
        throw AnubisError.mlxNotAvailable(reason: "MLX inference not yet implemented. Model path: \(modelPath)")
    }
}

// MARK: - MLX Config Types

private struct MLXConfigFile: Codable {
    let modelType: String?
    let hiddenSize: Int?
    let numHiddenLayers: Int?
    let numAttentionHeads: Int?
    let vocabSize: Int?
    let maxPositionEmbeddings: Int?

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case hiddenSize = "hidden_size"
        case numHiddenLayers = "num_hidden_layers"
        case numAttentionHeads = "num_attention_heads"
        case vocabSize = "vocab_size"
        case maxPositionEmbeddings = "max_position_embeddings"
    }
}
