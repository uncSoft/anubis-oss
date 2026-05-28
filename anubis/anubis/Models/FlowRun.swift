//
//  FlowRun.swift
//  anubis
//
//  A FlowRun is a *single execution* of a Flow. It captures the
//  flow's name and steps_json at the moment of execution so the
//  history view stays meaningful even after the parent Flow is
//  edited or deleted (orphan resilience). Every BenchmarkSession
//  produced during the run is tagged with this FlowRun's id via
//  benchmark_session.flow_run_id (and the same on
//  benchmark_run_group), so the Flow Report view is a simple
//  filtered query.
//

import Foundation
@preconcurrency import GRDB

/// Lifecycle status for a flow execution.
enum FlowRunStatus: String, Codable, DatabaseValueConvertible {
    case running
    case completed
    case failed
    case cancelled
}

struct FlowRun: Identifiable, Codable, Hashable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "flow_run"

    var id: Int64?
    var flowId: Int64
    var flowNameSnapshot: String
    var stepsJSONSnapshot: String
    var startedAt: Date
    var endedAt: Date?
    var status: FlowRunStatus
    var failureMessage: String?

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case flowId = "flow_id"
        case flowNameSnapshot = "flow_name_snapshot"
        case stepsJSONSnapshot = "steps_json_snapshot"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case status
        case failureMessage = "failure_message"
    }

    /// Snapshot the flow at the moment of execution. flowId is
    /// captured even though the row may later be deleted (the
    /// FK is ON DELETE SET NULL upstream so history survives).
    init(flow: Flow) {
        self.id = nil
        self.flowId = flow.id ?? 0
        self.flowNameSnapshot = flow.name
        self.stepsJSONSnapshot = flow.stepsJSON
        self.startedAt = Date()
        self.endedAt = nil
        self.status = .running
        self.failureMessage = nil
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Database Operations

extension FlowRun {
    /// All flow runs, most recent first.
    static func fetchAll(db: Database) throws -> [FlowRun] {
        try FlowRun.order(Column("started_at").desc).fetchAll(db)
    }

    /// All runs belonging to a given flow, most recent first.
    static func fetchByFlowID(db: Database, flowId: Int64) throws -> [FlowRun] {
        try FlowRun
            .filter(Column("flow_id") == flowId)
            .order(Column("started_at").desc)
            .fetchAll(db)
    }

    static func fetchByID(db: Database, id: Int64) throws -> FlowRun? {
        try FlowRun.fetchOne(db, key: id)
    }

    /// All benchmark sessions tagged with this flow run, ordered by
    /// start time. Used by FlowReportView.
    func sessions(db: Database) throws -> [BenchmarkSession] {
        try BenchmarkSession
            .filter(Column("flow_run_id") == id)
            .order(Column("started_at"))
            .fetchAll(db)
    }
}
