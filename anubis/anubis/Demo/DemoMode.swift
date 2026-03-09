//
//  DemoMode.swift
//  anubis
//
//  Created on 2026-01-31.
//

import Foundation

/// Configuration and detection for Demo Mode
/// Used for App Store review when Ollama/MLX backends are unavailable
enum DemoMode {
    /// Check if the app was launched with --demo flag
    /// Can also be enabled programmatically for testing
    private static var _forceEnabled: Bool = false

    static var isEnabled: Bool {
        _forceEnabled || ProcessInfo.processInfo.arguments.contains("--demo")
    }

    /// Force enable demo mode (for testing)
    static func setEnabled(_ enabled: Bool) {
        _forceEnabled = enabled
    }

    /// Demo mode configuration
    struct Config {
        /// Simulated typing delay between tokens (milliseconds)
        static let tokenDelayMs: UInt64 = 25

        /// Variation in token delay for realistic feel (milliseconds)
        static let tokenDelayVariation: UInt64 = 15

        /// Simulated model load time (milliseconds)
        static let modelLoadDelayMs: UInt64 = 500
    }
}

// MARK: - Demo Model Data

extension DemoMode {
    /// Realistic mock models for demonstration
    static let mockModels: [ModelInfo] = [
        // Ollama models
        ModelInfo(
            id: "llama3.2:3b",
            name: "llama3.2:3b",
            family: "llama",
            parameterCount: 3.0,
            quantization: "Q4_K_M",
            modelFormat: .gguf,
            sizeBytes: 2_100_000_000,
            contextLength: 8192,
            backend: .ollama,
            openAIConfigId: nil,
            path: nil,
            modifiedAt: Date()
        ),
        ModelInfo(
            id: "llama3.2:7b",
            name: "llama3.2:7b",
            family: "llama",
            parameterCount: 7.0,
            quantization: "Q4_K_M",
            modelFormat: .gguf,
            sizeBytes: 4_100_000_000,
            contextLength: 8192,
            backend: .ollama,
            openAIConfigId: nil,
            path: nil,
            modifiedAt: Date()
        ),
        ModelInfo(
            id: "mistral:7b",
            name: "mistral:7b",
            family: "mistral",
            parameterCount: 7.0,
            quantization: "Q4_K_M",
            modelFormat: .gguf,
            sizeBytes: 4_300_000_000,
            contextLength: 32768,
            backend: .ollama,
            openAIConfigId: nil,
            path: nil,
            modifiedAt: Date().addingTimeInterval(-86400)
        ),
        ModelInfo(
            id: "qwen2.5:7b",
            name: "qwen2.5:7b",
            family: "qwen",
            parameterCount: 7.0,
            quantization: "Q4_K_M",
            modelFormat: .gguf,
            sizeBytes: 4_400_000_000,
            contextLength: 32768,
            backend: .ollama,
            openAIConfigId: nil,
            path: nil,
            modifiedAt: Date().addingTimeInterval(-172800)
        ),
        ModelInfo(
            id: "phi3:mini",
            name: "phi3:mini",
            family: "phi",
            parameterCount: 3.8,
            quantization: "Q4_K_M",
            modelFormat: .gguf,
            sizeBytes: 2_400_000_000,
            contextLength: 4096,
            backend: .ollama,
            openAIConfigId: nil,
            path: nil,
            modifiedAt: Date().addingTimeInterval(-259200)
        ),
        ModelInfo(
            id: "gemma2:2b",
            name: "gemma2:2b",
            family: "gemma",
            parameterCount: 2.0,
            quantization: "Q4_K_M",
            modelFormat: .gguf,
            sizeBytes: 1_600_000_000,
            contextLength: 8192,
            backend: .ollama,
            openAIConfigId: nil,
            path: nil,
            modifiedAt: Date().addingTimeInterval(-345600)
        ),
    ]
}

// MARK: - Demo Responses

extension DemoMode {
    /// Pre-written responses for various prompt categories
    static func responseFor(prompt: String) -> String {
        let lowerPrompt = prompt.lowercased()

        // Math/reasoning prompts
        if lowerPrompt.contains("fibonacci") || lowerPrompt.contains("sequence") {
            return """
            The Fibonacci sequence is a series of numbers where each number is the sum of the two preceding ones.

            Starting from 0 and 1:
            0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144...

            The pattern continues infinitely. In code:

            ```python
            def fibonacci(n):
                if n <= 1:
                    return n
                return fibonacci(n-1) + fibonacci(n-2)
            ```

            The sequence appears throughout nature, from spiral galaxies to sunflower seed patterns.
            """
        }

        // Coding prompts
        if lowerPrompt.contains("code") || lowerPrompt.contains("function") || lowerPrompt.contains("program") {
            return """
            Here's a clean implementation:

            ```swift
            func processData(_ items: [Item]) -> [Result] {
                items.compactMap { item in
                    guard item.isValid else { return nil }
                    return Result(
                        id: item.id,
                        value: transform(item.value),
                        timestamp: Date()
                    )
                }
            }
            ```

            This uses `compactMap` to filter and transform in one pass, which is both readable and efficient. The guard statement handles invalid items gracefully by returning nil, which compactMap automatically filters out.
            """
        }

        // Explanation prompts
        if lowerPrompt.contains("explain") || lowerPrompt.contains("what is") || lowerPrompt.contains("how does") {
            return """
            Let me break this down into clear parts:

            **Core Concept**
            At its heart, this involves processing information through multiple stages, each building on the previous one.

            **Key Components**
            1. Input layer - receives and normalizes data
            2. Processing layers - transform and analyze
            3. Output layer - produces the final result

            **Why It Matters**
            Understanding these fundamentals helps you debug issues faster and make better architectural decisions.

            **Practical Application**
            In real-world scenarios, you'd typically want to add caching at stage 2 and validation at stages 1 and 3.
            """
        }

        // Creative prompts
        if lowerPrompt.contains("story") || lowerPrompt.contains("creative") || lowerPrompt.contains("write") {
            return """
            The old lighthouse keeper had seen many storms, but nothing quite like this.

            The wind howled through the gaps in the ancient stone walls as she climbed the spiral staircase, lantern in hand. Each step creaked with decades of memories - her father's footsteps, her grandfather's before that.

            At the top, the great lens caught her lamplight and scattered it across the ceiling like stars. Outside, waves crashed against the rocks with thunderous fury.

            "Just another night," she whispered to the darkness, and began her watch.
            """
        }

        // Default response for benchmarking
        return """
        Thank you for your question. Let me provide a comprehensive response.

        When approaching this topic, there are several key considerations to keep in mind:

        **First**, we need to establish the fundamental principles. These form the foundation for everything that follows.

        **Second**, practical application matters. Theory without practice rarely leads to meaningful results.

        **Third**, iteration is essential. The first solution is rarely the best one, but it's a necessary starting point.

        In conclusion, the most effective approach combines solid fundamentals with hands-on experimentation and continuous refinement. This methodology has proven successful across a wide range of scenarios and scales well as complexity increases.

        Would you like me to elaborate on any specific aspect of this topic?
        """
    }
}
