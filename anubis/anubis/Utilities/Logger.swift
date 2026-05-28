//
//  Logger.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation
import os.log

/// Signpost logs for Instruments profiling (Time Profiler / os_signpost)
enum Signposts {
    /// Streaming performance intervals — visible in Instruments → os_signpost
    static let streaming = OSLog(subsystem: "com.uncsoft.anubis", category: .pointsOfInterest)
}

/// Unified logging for Anubis
enum Log {
    /// Logger for general app events
    static let app = Logger(subsystem: "com.uncsoft.anubis", category: "app")

    /// Logger for inference operations
    static let inference = Logger(subsystem: "com.uncsoft.anubis", category: "inference")

    /// Logger for metrics collection
    static let metrics = Logger(subsystem: "com.uncsoft.anubis", category: "metrics")

    /// Logger for database operations
    static let database = Logger(subsystem: "com.uncsoft.anubis", category: "database")

    /// Logger for network operations
    static let network = Logger(subsystem: "com.uncsoft.anubis", category: "network")

    /// Logger for benchmark operations
    static let benchmark = Logger(subsystem: "com.uncsoft.anubis", category: "benchmark")

    /// Logger for vault operations
    static let vault = Logger(subsystem: "com.uncsoft.anubis", category: "vault")

    /// Logger for Flow Builder operations
    static let flows = Logger(subsystem: "com.uncsoft.anubis", category: "flows")
}

// MARK: - Convenience Extensions

extension Logger {
    /// Log an error with context
    func error(_ error: Error, context: String? = nil) {
        if let context = context {
            self.error("\(context): \(error.localizedDescription)")
        } else {
            self.error("\(error.localizedDescription)")
        }
    }

    /// Log performance timing
    func timing(_ operation: String, duration: TimeInterval) {
        self.info("\(operation) completed in \(String(format: "%.2f", duration * 1000))ms")
    }
}
