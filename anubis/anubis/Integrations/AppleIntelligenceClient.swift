//
//  AppleIntelligenceClient.swift
//  anubis
//
//  Created on 2026-04-21.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device Apple Intelligence backend backed by Apple's Foundation Models framework.
/// Requires macOS 26 (Tahoe) and an Apple Silicon device with Apple Intelligence enabled.
actor AppleIntelligenceClient: InferenceBackend {
    let backendType: InferenceBackendType = .appleIntelligence

    static let modelID = "apple-intelligence-system"
    static let modelDisplayName = "Apple Intelligence (on-device)"

    var isAvailable: Bool {
        get async {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                if case .available = SystemLanguageModel.default.availability {
                    return true
                }
            }
            #endif
            return false
        }
    }

    func checkHealth() async -> BackendHealth {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .healthy(version: "Foundation Models", modelCount: 1)
            case .unavailable(let reason):
                return .unhealthy(error: Self.describe(reason))
            @unknown default:
                return .unhealthy(error: "Apple Intelligence availability unknown")
            }
        }
        #endif
        return .unhealthy(error: "Requires macOS 26 (Tahoe) or later")
    }

    func listModels() async throws -> [ModelInfo] {
        guard await isAvailable else { return [] }
        return [
            ModelInfo(
                id: Self.modelID,
                name: Self.modelDisplayName,
                family: "apple-foundation",
                parameterCount: 3.0,
                quantization: "INT4 (Apple)",
                modelFormat: nil,
                sizeBytes: nil,
                contextLength: 4096,
                backend: .appleIntelligence,
                openAIConfigId: nil,
                path: nil,
                modifiedAt: nil
            )
        ]
    }

    func generate(request: InferenceRequest) -> AsyncThrowingStream<InferenceChunk, Error> {
        AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let task = Task {
                    do {
                        try await Self.runStream(request: request, continuation: continuation)
                    } catch is CancellationError {
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
                return
            }
            #endif
            continuation.finish(throwing: AnubisError.backendNotRunning(backend: "Apple Intelligence (requires macOS 26+)"))
        }
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func runStream(
        request: InferenceRequest,
        continuation: AsyncThrowingStream<InferenceChunk, Error>.Continuation
    ) async throws {
        guard case .available = SystemLanguageModel.default.availability else {
            throw AnubisError.backendNotRunning(backend: "Apple Intelligence")
        }

        let session: LanguageModelSession
        if let sys = request.systemPrompt, !sys.isEmpty {
            session = LanguageModelSession(instructions: Instructions(sys))
        } else {
            session = LanguageModelSession()
        }

        let options: GenerationOptions
        if let temp = request.temperature, let maxTokens = request.maxTokens {
            options = GenerationOptions(temperature: temp, maximumResponseTokens: maxTokens)
        } else if let temp = request.temperature {
            options = GenerationOptions(temperature: temp)
        } else if let maxTokens = request.maxTokens {
            options = GenerationOptions(maximumResponseTokens: maxTokens)
        } else {
            options = GenerationOptions()
        }

        let startTime = Date()
        var firstTokenTime: Date?
        var emitted = ""

        let stream = session.streamResponse(to: request.prompt, options: options)
        for try await snapshot in stream {
            let cumulative = snapshot.content
            guard cumulative.count > emitted.count else { continue }
            let delta = String(cumulative.dropFirst(emitted.count))
            if firstTokenTime == nil { firstTokenTime = Date() }
            emitted = cumulative
            continuation.yield(InferenceChunk(text: delta, done: false))
        }

        let endTime = Date()
        let firstToken = firstTokenTime ?? endTime

        // Foundation Models doesn't surface tokenizer counts, so approximate
        // (~4 chars/token) — keeps tok/s comparable to GGUF/MLX backends.
        let promptTokens = max(1, request.prompt.count / 4)
        let completionTokens = max(1, emitted.count / 4)

        let stats = InferenceStats(
            totalTokens: promptTokens + completionTokens,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalDuration: endTime.timeIntervalSince(startTime),
            promptEvalDuration: firstToken.timeIntervalSince(startTime),
            evalDuration: max(0.000_001, endTime.timeIntervalSince(firstToken)),
            loadDuration: 0,
            contextLength: 4096
        )
        continuation.yield(InferenceChunk(text: "", done: true, stats: stats))
        continuation.finish()
    }

    @available(macOS 26.0, *)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This device is not eligible for Apple Intelligence"
        case .appleIntelligenceNotEnabled:
            return "Enable Apple Intelligence in System Settings"
        case .modelNotReady:
            return "Apple Intelligence model is still downloading"
        @unknown default:
            return "Apple Intelligence is unavailable"
        }
    }
    #endif
}
