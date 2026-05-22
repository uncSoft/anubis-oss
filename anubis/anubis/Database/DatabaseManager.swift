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

        // Snapshot the DB before running migrations so a botched v7+
        // data-rewrite (power scale fix) is recoverable. The backup is
        // taken once per unique pre-migration state — if the user has
        // already migrated and is on v7+ the backup is skipped.
        backupBeforeNewMigrationsIfNeeded()

        // Run migrations
        try migrate()
        isInitialized = true
    }

    /// Copy the DB to anubis.sqlite.pre-vN.bak before running any
    /// new data-rewriting migration so users have a snapshot they
    /// can restore if a migration produces unexpected results.
    private func backupBeforeNewMigrationsIfNeeded() {
        // Only relevant if the live DB exists and we haven't already
        // taken the v7 backup.
        let fm = FileManager.default
        guard fm.fileExists(atPath: databaseURL.path) else { return }
        let backupURL = databaseURL.appendingPathExtension("pre-v7.bak")
        guard !fm.fileExists(atPath: backupURL.path) else { return }
        do {
            try fm.copyItem(at: databaseURL, to: backupURL)
        } catch {
            // Backup failure shouldn't block app launch — the migration
            // itself runs inside a GRDB transaction, so this is belt-and-
            // suspenders. Log only.
            print("DatabaseManager: pre-v7 backup failed: \(error.localizedDescription)")
        }
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

        // Migration v5: Model quantization and format
        migrator.registerMigration("v5") { db in
            try db.alter(table: "benchmark_session") { t in
                t.add(column: "model_quantization", .text)
                t.add(column: "model_format", .text)
            }
        }

        // Migration v6: Reasoning/thinking token accounting (issues #17, #18)
        migrator.registerMigration("v6") { db in
            try db.alter(table: "benchmark_session") { t in
                t.add(column: "reasoning_tokens", .integer)
                t.add(column: "reasoning_duration", .double)
            }
        }

        // Migration v7: Fix CPU/ANE/DRAM power scale (#? — v3.4).
        //
        // Before v3.4, parseEnergyDelta assumed all IOReport Energy Model
        // channels returned values in nanojoules. That's correct for GPU
        // Energy but wrong for ECPU/PCPU/ANE/DRAM, which return millijoules
        // — so historical cpu/ane/dram per-sample readings were stored
        // ~10⁶× too small (µW instead of W), and systemPower (the sum)
        // was effectively just GPU. avgWattsPerToken at session level was
        // therefore an undercount (missed CPU/ANE/DRAM contribution).
        //
        // Notes on the historical data this migration is correcting:
        //  - The clean nJ-bug rows have cpu/ane/dram in the 1 µW – 1 mW
        //    range. Multiplying by 10⁶ brings them to 1 – 1000 W, which
        //    is approximately right (CPU under load = 5–25 W on Apple
        //    Silicon).
        //  - Some pre-existing DB rows have impossibly high system_power
        //    (up to ~60,000 W) from earlier code-era bugs unrelated to
        //    this fix. The threshold (< 1 mW) deliberately excludes those
        //    so we don't compound the damage. A post-rescale sanity sweep
        //    nulls per-channel values that come out above 200 W (which is
        //    higher than any realistic Apple Silicon SoC component) and
        //    leaves the row visible but with the bad value zeroed out.
        //
        // The pre-migration DB is backed up to anubis.sqlite.pre-v7.bak
        // outside this transaction (see backupBeforeNewMigrationsIfNeeded).
        migrator.registerMigration("v7") { db in
            let scale = 1_000_000.0
            // Rescale only the clean µW bug range. Anything ≥ 1 mW
            // pre-migration is either (a) already correct from a post-
            // v3.4 sample written during testing, or (b) historical
            // garbage from a different bug pattern — either way, leave
            // it alone.
            let upperBound = 1e-3

            // 1. Rescale per-sample channels that match the µW bug pattern.
            try db.execute(sql: """
                UPDATE benchmark_sample
                SET cpu_power_watts = cpu_power_watts * \(scale)
                WHERE cpu_power_watts IS NOT NULL AND cpu_power_watts > 0 AND cpu_power_watts < \(upperBound)
                """)
            try db.execute(sql: """
                UPDATE benchmark_sample
                SET ane_power_watts = ane_power_watts * \(scale)
                WHERE ane_power_watts IS NOT NULL AND ane_power_watts > 0 AND ane_power_watts < \(upperBound)
                """)
            try db.execute(sql: """
                UPDATE benchmark_sample
                SET dram_power_watts = dram_power_watts * \(scale)
                WHERE dram_power_watts IS NOT NULL AND dram_power_watts > 0 AND dram_power_watts < \(upperBound)
                """)

            // 2. Sanity cap: NULL any per-channel value that came out
            // implausibly high (> 200 W per channel is impossible on
            // Apple Silicon SoC components). Catches outliers from
            // historical garbage rows.
            let perChannelCap = 200.0
            try db.execute(sql: "UPDATE benchmark_sample SET cpu_power_watts = NULL WHERE cpu_power_watts > \(perChannelCap)")
            try db.execute(sql: "UPDATE benchmark_sample SET ane_power_watts = NULL WHERE ane_power_watts > \(perChannelCap)")
            try db.execute(sql: "UPDATE benchmark_sample SET dram_power_watts = NULL WHERE dram_power_watts > \(perChannelCap)")
            try db.execute(sql: "UPDATE benchmark_sample SET gpu_power_watts = NULL WHERE gpu_power_watts > \(perChannelCap)")

            // 3. Recompute per-sample system_power_watts from the now-
            // corrected channels. COALESCE so NULLs don't blow up the sum.
            try db.execute(sql: """
                UPDATE benchmark_sample
                SET system_power_watts =
                    COALESCE(gpu_power_watts, 0)
                  + COALESCE(cpu_power_watts, 0)
                  + COALESCE(ane_power_watts, 0)
                  + COALESCE(dram_power_watts, 0)
                WHERE gpu_power_watts IS NOT NULL
                   OR cpu_power_watts IS NOT NULL
                   OR ane_power_watts IS NOT NULL
                   OR dram_power_watts IS NOT NULL
                """)

            // 4. Sanity cap system_power_watts too — the sum should never
            // exceed ~300 W on any Apple Silicon chip.
            let systemCap = 300.0
            try db.execute(sql: "UPDATE benchmark_sample SET system_power_watts = NULL WHERE system_power_watts > \(systemCap)")

            // 5. Re-aggregate session-level avg/peak system_power_watts
            // from the corrected (and sanity-capped) sample data.
            try db.execute(sql: """
                UPDATE benchmark_session
                SET avg_system_power_watts = (
                        SELECT AVG(system_power_watts) FROM benchmark_sample s
                        WHERE s.session_id = benchmark_session.id
                          AND s.system_power_watts IS NOT NULL
                          AND s.system_power_watts > 0
                    ),
                    peak_system_power_watts = (
                        SELECT MAX(system_power_watts) FROM benchmark_sample s
                        WHERE s.session_id = benchmark_session.id
                          AND s.system_power_watts IS NOT NULL
                          AND s.system_power_watts > 0
                    )
                WHERE EXISTS (
                    SELECT 1 FROM benchmark_sample s
                    WHERE s.session_id = benchmark_session.id
                )
                """)

            // 6. Recompute avg_watts_per_token (J/tok) from the corrected
            // session-level avg power and the existing tokens_per_second.
            try db.execute(sql: """
                UPDATE benchmark_session
                SET avg_watts_per_token = avg_system_power_watts / tokens_per_second
                WHERE avg_system_power_watts IS NOT NULL
                  AND tokens_per_second IS NOT NULL
                  AND tokens_per_second > 0
                """)
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
