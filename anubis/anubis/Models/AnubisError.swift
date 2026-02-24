//
//  AnubisError.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation

/// Errors that can occur during Anubis operations
enum AnubisError: LocalizedError {
    case backendNotRunning(backend: String)
    case modelLoadFailed(modelId: String, reason: String)
    case inferenceTimeout(after: TimeInterval)
    case metricsUnavailable(reason: String)
    case networkError(underlying: Error)
    case invalidResponse(details: String)
    case modelNotFound(modelId: String)
    case streamingError(reason: String)
    case databaseError(underlying: Error)
    case mlxNotAvailable(reason: String)
    case invalidOperation(reason: String)
    case leaderboardError(reason: String)

    var errorDescription: String? {
        switch self {
        case .backendNotRunning(let backend):
            return "\(backend) is not running"
        case .modelLoadFailed(let modelId, let reason):
            return "Failed to load model '\(modelId)': \(reason)"
        case .inferenceTimeout(let after):
            return "Inference timed out after \(Int(after)) seconds"
        case .metricsUnavailable(let reason):
            return "Hardware metrics unavailable: \(reason)"
        case .networkError(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .invalidResponse(let details):
            return "Invalid response from backend: \(details)"
        case .modelNotFound(let modelId):
            return "Model '\(modelId)' not found"
        case .streamingError(let reason):
            return "Streaming error: \(reason)"
        case .databaseError(let underlying):
            return "Database error: \(underlying.localizedDescription)"
        case .mlxNotAvailable(let reason):
            return "MLX not available: \(reason)"
        case .invalidOperation(let reason):
            return "Invalid operation: \(reason)"
        case .leaderboardError(let reason):
            return "Leaderboard error: \(reason)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .backendNotRunning(let backend):
            if backend == "Ollama" {
                return "Start Ollama by running 'ollama serve' in Terminal, or download from https://ollama.ai"
            } else {
                return "Ensure \(backend) is properly installed and running"
            }
        case .modelLoadFailed:
            return "Try pulling the model again or check available disk space"
        case .inferenceTimeout:
            return "Try a smaller model or reduce the prompt length"
        case .metricsUnavailable:
            return "Some hardware metrics may require additional permissions"
        case .networkError:
            return "Check your network connection and try again"
        case .invalidResponse:
            return "The backend may need to be restarted"
        case .modelNotFound(let modelId):
            return "Pull the model using 'ollama pull \(modelId)'"
        case .streamingError:
            return "Try the request again"
        case .databaseError:
            return "Try restarting the application"
        case .mlxNotAvailable:
            return "Ensure mlx-swift is properly installed"
        case .invalidOperation:
            return nil
        case .leaderboardError:
            return "Check your internet connection and try again"
        }
    }
}
