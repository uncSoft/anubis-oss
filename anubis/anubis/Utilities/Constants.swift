//
//  Constants.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation

/// App-wide constants
enum Constants {
    // MARK: - URLs

    enum URLs {
        static let ollamaDefault = URL(string: "http://localhost:11434")!
        static let openAIDefault = URL(string: "http://localhost:8080")!
        static let privacyPolicy = URL(string: "https://devpadapp.com/anubis/privacy.html")!
        static let website = URL(string: "https://devpadapp.com/anubis-oss.html")!
        static let leaderboardAPI = URL(string: "https://devpadapp.com/anubis/api/")!
        static let leaderboardPage = URL(string: "https://devpadapp.com/leaderboard.html")!

        /// Safely parse a URL string with a fallback
        static func parse(_ string: String, fallback: URL) -> URL {
            URL(string: string) ?? fallback
        }
    }

    // MARK: - Ollama

    enum Ollama {
        static let defaultBaseURL = URLs.ollamaDefault
        static let healthCheckTimeout: TimeInterval = 5
        static let requestTimeout: TimeInterval = 300
        static let resourceTimeout: TimeInterval = 600
    }

    // MARK: - Metrics

    enum Metrics {
        static let defaultPollingInterval: TimeInterval = 0.5
        static let throttledPollingInterval: TimeInterval = 1.0
        static let maxHistoryDuration: TimeInterval = 300 // 5 minutes
        static let maxHistorySamples = 600
    }

    // MARK: - Benchmark

    enum Benchmark {
        static let defaultWarmupPrompt = "Hello"
        static let defaultTestPrompts = [
            "Explain quantum computing in simple terms.",
            "Write a haiku about programming.",
            "What are the benefits of functional programming?",
            "Describe the water cycle in one paragraph.",
            "List five tips for writing clean code."
        ]
    }

    // MARK: - Leaderboard

    enum Leaderboard {
        static let maxDisplayNameLength = 64
    }

    // MARK: - Arena

    enum Arena {
        static let maxConcurrentTests = 2
        static let defaultTimeout: TimeInterval = 60
    }

    // MARK: - Database

    enum Database {
        static let fileName = "anubis.sqlite"
        static let maxResultsPerQuery = 1000
    }

    // MARK: - UI

    enum UI {
        static let defaultWindowWidth: CGFloat = 1200
        static let defaultWindowHeight: CGFloat = 800
        static let minWindowWidth: CGFloat = 800
        static let minWindowHeight: CGFloat = 600
        static let sidebarWidth: CGFloat = 220
    }

    // MARK: - User Defaults Keys

    enum UserDefaultsKeys {
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let selectedBackend = "selectedBackend"
        static let ollamaBaseURL = "ollamaBaseURL"
        static let metricsPollingInterval = "metricsPollingInterval"
        static let mlxModelDirectories = "mlxModelDirectories"
        static let leaderboardDisplayName = "leaderboardDisplayName"
    }
}
