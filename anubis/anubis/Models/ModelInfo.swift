//
//  ModelInfo.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation

/// Backend type for inference
enum InferenceBackendType: String, Codable, CaseIterable, Identifiable {
    case ollama = "Ollama"
    case openai = "OpenAI Compatible"
    case appleIntelligence = "Apple Intelligence"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var icon: String {
        switch self {
        case .ollama: return "server.rack"
        case .openai: return "globe"
        case .appleIntelligence: return "apple.logo"
        }
    }
}

/// Model file format
enum ModelFormat: String, Codable, CaseIterable {
    case gguf = "GGUF"
    case mlx = "MLX"
    case unknown = "Unknown"

    var displayName: String { rawValue }
}

/// Information about a model available for inference
struct ModelInfo: Identifiable, Hashable, Codable {
    /// Unique identifier for the model
    let id: String

    /// Display name of the model
    let name: String

    /// Model family/architecture (e.g., "llama", "mistral", "qwen")
    let family: String?

    /// Parameter count in billions (e.g., 3.0 for 3B)
    let parameterCount: Double?

    /// Quantization type (e.g., "Q4_K_M", "Q5_K_S", "f16")
    let quantization: String?

    /// Model file format (GGUF, MLX)
    let modelFormat: ModelFormat?

    /// Model size on disk in bytes
    let sizeBytes: Int64?

    /// Context window size
    let contextLength: Int?

    /// Backend this model is available on
    let backend: InferenceBackendType

    /// For OpenAI-compatible backends, the config ID this model belongs to
    let openAIConfigId: UUID?

    /// Path to the model file on disk
    let path: String?

    /// When the model was last modified
    let modifiedAt: Date?

    /// Formatted size for display
    var formattedSize: String {
        guard let bytes = sizeBytes else { return "Unknown" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Formatted parameter count for display
    var formattedParameters: String {
        guard let count = parameterCount else { return "Unknown" }
        if count >= 1 {
            return String(format: "%.1fB", count)
        } else {
            return String(format: "%.0fM", count * 1000)
        }
    }
}

/// Extended metadata for GGUF models
struct GGUFMetadata: Codable {
    let architecture: String
    let parameterCount: Int64
    let contextLength: Int
    let embeddingLength: Int
    let blockCount: Int
    let vocabSize: Int
    let quantizationType: String
}
