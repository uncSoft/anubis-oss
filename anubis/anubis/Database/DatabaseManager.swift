//
//  DatabaseManager.swift
//  anubis
//
//  Created on 2026-01-25.
//

import Foundation
import GRDB

/// Manages the SQLite database using GRDB
final class DatabaseManager {
    /// Shared instance
    static let shared = DatabaseManager()

    /// Database queue for thread-safe access
    private var dbQueue: DatabaseQueue?

    /// Database file URL
    private let databaseURL: URL

    /// Whether the database is initialized
    private(set) var isInitialized = false

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let anubisDir = appSupport.appendingPathComponent("Anubis", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: anubisDir, withIntermediateDirectories: true)

        databaseURL = anubisDir.appendingPathComponent("anubis.sqlite")
    }

    /// Initialize the database
    func initialize() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true

        dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)

        // Run migrations
        try migrate()
        isInitialized = true
    }

    /// Get the database queue for operations
    var queue: DatabaseQueue {
        guard let queue = dbQueue else {
            fatalError("Database not initialized. Call initialize() first.")
        }
        return queue
    }

    // MARK: - Migrations

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        // Migration v1: Initial schema
        migrator.registerMigration("v1") { db in
            // Benchmark sessions
            try db.create(table: "benchmark_session") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("model_id", .text).notNull()
                t.column("model_name", .text).notNull()
                t.column("backend", .text).notNull()
                t.column("started_at", .datetime).notNull()
                t.column("ended_at", .datetime)
                t.column("prompt", .text).notNull()
                t.column("response", .text)
                t.column("total_tokens", .integer)
                t.column("prompt_tokens", .integer)
                t.column("completion_tokens", .integer)
                t.column("tokens_per_second", .double)
                t.column("total_duration", .double)
                t.column("prompt_eval_duration", .double)
                t.column("eval_duration", .double)
                t.column("status", .text).notNull().defaults(to: "running")
            }

            // Benchmark samples (time-series metrics)
            try db.create(table: "benchmark_sample") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("session_id", .integer)
                    .notNull()
                    .references("benchmark_session", onDelete: .cascade)
                t.column("timestamp", .datetime).notNull()
                t.column("gpu_utilization", .double)
                t.column("cpu_utilization", .double)
                t.column("ane_power_watts", .double)
                t.column("memory_used_bytes", .integer)
                t.column("memory_total_bytes", .integer)
                t.column("thermal_state", .integer)
                t.column("tokens_generated", .integer)
                t.column("cumulative_tokens_per_second", .double)
            }

            // Test suites for Arena
            try db.create(table: "test_suite") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            // Test cases within suites
            try db.create(table: "test_case") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("suite_id", .integer)
                    .notNull()
                    .references("test_suite", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("prompt", .text).notNull()
                t.column("system_prompt", .text)
                t.column("expected_contains", .text) // JSON array
                t.column("expected_not_contains", .text) // JSON array
                t.column("max_latency_ms", .integer)
                t.column("min_length", .integer)
                t.column("max_length", .integer)
                t.column("order_index", .integer).notNull().defaults(to: 0)
            }

            // Test results
            try db.create(table: "test_result") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("case_id", .integer)
                    .notNull()
                    .references("test_case", onDelete: .cascade)
                t.column("model_id", .text).notNull()
                t.column("backend", .text).notNull()
                t.column("run_at", .datetime).notNull()
                t.column("response", .text)
                t.column("latency_ms", .integer)
                t.column("passed", .boolean).notNull()
                t.column("failure_reason", .text)
                t.column("tokens_per_second", .double)
            }

            // Create indexes
            try db.create(index: "idx_benchmark_sample_session", on: "benchmark_sample", columns: ["session_id"])
            try db.create(index: "idx_test_case_suite", on: "test_case", columns: ["suite_id"])
            try db.create(index: "idx_test_result_case", on: "test_result", columns: ["case_id"])
        }

        // Migration v2: Additional benchmark metrics
        migrator.registerMigration("v2") { db in
            // Add new columns to benchmark_session
            try db.alter(table: "benchmark_session") { t in
                t.add(column: "time_to_first_token", .double)
                t.add(column: "load_duration", .double)
                t.add(column: "context_length", .integer)
                t.add(column: "peak_memory_bytes", .integer)
                t.add(column: "avg_token_latency_ms", .double)
            }
        }

        // Migration v3: Arena comparisons
        migrator.registerMigration("v3") { db in
            try db.create(table: "arena_comparison") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("session_a_id", .integer)
                    .notNull()
                    .references("benchmark_session", onDelete: .cascade)
                t.column("session_b_id", .integer)
                    .notNull()
                    .references("benchmark_session", onDelete: .cascade)
                t.column("prompt", .text).notNull()
                t.column("system_prompt", .text)
                t.column("execution_mode", .text).notNull()
                t.column("winner", .text)
                t.column("notes", .text)
                t.column("created_at", .datetime).notNull()
            }

            try db.create(index: "idx_arena_comparison_sessions", on: "arena_comparison", columns: ["session_a_id", "session_b_id"])
        }

        // Migration v4: Power metrics, frequency, backend process info, chip info
        migrator.registerMigration("v4") { db in
            // benchmark_sample — 8 new columns for time-series power data
            try db.alter(table: "benchmark_sample") { t in
                t.add(column: "gpu_power_watts", .double)
                t.add(column: "cpu_power_watts", .double)
                t.add(column: "dram_power_watts", .double)
                t.add(column: "system_power_watts", .double)
                t.add(column: "gpu_frequency_mhz", .double)
                t.add(column: "backend_process_memory_bytes", .integer)
                t.add(column: "backend_process_cpu_percent", .double)
                t.add(column: "watts_per_token", .double)
            }

            // benchmark_session — 9 new columns for aggregate stats
            try db.alter(table: "benchmark_session") { t in
                t.add(column: "avg_gpu_power_watts", .double)
                t.add(column: "peak_gpu_power_watts", .double)
                t.add(column: "avg_system_power_watts", .double)
                t.add(column: "peak_system_power_watts", .double)
                t.add(column: "avg_gpu_frequency_mhz", .double)
                t.add(column: "peak_gpu_frequency_mhz", .double)
                t.add(column: "avg_watts_per_token", .double)
                t.add(column: "backend_process_name", .text)
                t.add(column: "chip_info_json", .text)
            }
        }

        try migrator.migrate(queue)
    }

    // MARK: - Convenience Methods

    /// Delete all data
    func reset() throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM benchmark_sample")
            try db.execute(sql: "DELETE FROM benchmark_session")
            try db.execute(sql: "DELETE FROM test_result")
            try db.execute(sql: "DELETE FROM test_case")
            try db.execute(sql: "DELETE FROM test_suite")
        }
    }

    /// Get database file size
    var databaseSize: Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: databaseURL.path),
              let size = attrs[.size] as? Int64 else {
            return 0
        }
        return size
    }
}
