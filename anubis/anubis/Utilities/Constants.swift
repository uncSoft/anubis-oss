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
        static let methodology = URL(string: "https://uncsoft.github.io/anubis-oss/methodology.html")!

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

    /// Seconds without a single streamed chunk before an inference run is
    /// declared stalled and aborted (issue #31). 0 disables the watchdog.
    /// Note this is idle time between chunks, NOT total run time — a slow
    /// model that keeps streaming never trips it.
    static var inferenceStallTimeout: TimeInterval {
        guard UserDefaults.standard.object(forKey: UserDefaultsKeys.inferenceStallTimeoutSeconds) != nil else {
            return 120
        }
        return UserDefaults.standard.double(forKey: UserDefaultsKeys.inferenceStallTimeoutSeconds)
    }

    enum UserDefaultsKeys {
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        // Stall watchdog window in seconds; 0 = disabled. See Constants.inferenceStallTimeout.
        static let inferenceStallTimeoutSeconds = "anubis.inferenceStallTimeoutSeconds"
        static let selectedBackend = "selectedBackend"
        static let ollamaBaseURL = "ollamaBaseURL"
        static let metricsPollingInterval = "metricsPollingInterval"
        static let mlxModelDirectories = "mlxModelDirectories"
        static let leaderboardDisplayName = "leaderboardDisplayName"
        // Opt-in auto-submission of completed runs to the community
        // leaderboard. Default false; only enabled when the user has
        // both flipped this toggle AND set a display name.
        static let autoSubmitLeaderboard = "anubis.autoSubmitLeaderboard"

        // Disclosure-group expansion state for the two collapsible
        // sections on the benchmark dashboard. Defaults to expanded
        // so first-time users see the N-runs + Thinking-toggle
        // affordances at least once; collapsed state then persists
        // after user changes it.
        static let benchmarkParametersExpanded = "anubis.benchmarkParametersExpanded"
        static let benchmarkPerformanceExpanded = "anubis.benchmarkPerformanceExpanded"
        // Last-used backend + model, restored on launch so the user lands
        // back on whatever they ran most recently (not the historical
        // Ollama default).
        static let lastUsedBackend = "lastUsedBackend"        // JSON PersistedBackendID
        static let lastUsedModelName = "lastUsedModelName"    // String, scoped to lastUsedBackend
        static let lastUsedAt = "lastUsedAt"                  // Date
    }
}
