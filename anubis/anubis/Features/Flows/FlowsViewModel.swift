//
//  FlowsViewModel.swift
//  anubis
//
//  Lightweight CRUD viewmodel for the Flows tab. Owns the list of
//  saved flows, the currently-selected flow, and the mutations that
//  persist edits back to the database. Editor UI lives in
//  FlowEditorView (Phase 2); for Phase 1 we just need new/rename/
//  delete and the empty placeholder.
//

import Foundation
import Combine
import GRDB
import os

@MainActor
final class FlowsViewModel: ObservableObject {
    // MARK: - Published State

    /// All saved flows, most recently updated first.
    @Published private(set) var flows: [Flow] = []

    /// Most-recent flow runs (cap of 20 in the sidebar to keep it
    /// scannable; clicking opens the full report).
    @Published private(set) var recentRuns: [FlowRun] = []

    /// Currently selected flow's id (drives the detail pane).
    @Published var selectedFlowID: Int64?

    /// Last error to surface in the UI.
    @Published var lastError: String?

    // MARK: - Dependencies

    private let databaseManager: DatabaseManager
    private var log: Logger { Log.flows }

    // MARK: - Init

    init(databaseManager: DatabaseManager) {
        self.databaseManager = databaseManager
        reload()
    }

    // MARK: - Derived

    /// The currently selected flow, or nil if none / not found.
    var selectedFlow: Flow? {
        guard let id = selectedFlowID else { return nil }
        return flows.first { $0.id == id }
    }

    // MARK: - CRUD

    /// Refresh the in-memory list from the database. Cheap; called
    /// after any mutation and on view appear.
    func reload() {
        do {
            let (fetchedFlows, fetchedRuns) = try databaseManager.queue.read { db in
                let flows = try Flow.fetchAll(db: db)
                let runs = try FlowRun.fetchAll(db: db)
                return (flows, runs)
            }
            self.flows = fetchedFlows
            // Cap recent runs at 20 — older history is still queryable
            // by id, just not surfaced in the sidebar.
            self.recentRuns = Array(fetchedRuns.prefix(20))
            // If the previously selected flow disappeared (deletion
            // from another window), drop the selection.
            if let id = selectedFlowID, !fetchedFlows.contains(where: { $0.id == id }) {
                selectedFlowID = nil
            }
        } catch {
            log.error("Failed to load flows: \(error.localizedDescription)")
            lastError = "Failed to load flows: \(error.localizedDescription)"
        }
    }

    /// Fetch a FlowRun + its sessions and assemble a report payload.
    /// Returns nil if the run doesn't exist or the DB read fails.
    func reportData(for run: FlowRun) -> FlowReportData? {
        do {
            let sessions = try databaseManager.queue.read { db in
                try run.sessions(db: db)
            }
            return FlowReportData.compute(flowRun: run, sessions: sessions)
        } catch {
            log.error("Failed to load report data: \(error.localizedDescription)")
            return nil
        }
    }

    /// Create a new empty flow and select it.
    func createFlow(name: String = "Untitled Flow") {
        var flow = Flow(name: name)
        do {
            try databaseManager.queue.write { db in
                try flow.insert(db)
            }
            reload()
            selectedFlowID = flow.id
        } catch {
            log.error("Failed to create flow: \(error.localizedDescription)")
            lastError = "Failed to create flow: \(error.localizedDescription)"
        }
    }

    /// Rename an existing flow.
    func renameFlow(_ flow: Flow, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var updated = flows.first(where: { $0.id == flow.id }) else { return }
        updated.name = trimmed
        updated.updatedAt = Date()
        do {
            try databaseManager.queue.write { db in
                try updated.update(db)
            }
            reload()
        } catch {
            log.error("Failed to rename flow: \(error.localizedDescription)")
            lastError = "Failed to rename flow: \(error.localizedDescription)"
        }
    }

    /// Delete a flow. Any historical FlowRun rows survive (the FK is
    /// ON DELETE SET NULL) so prior reports stay browsable.
    func deleteFlow(_ flow: Flow) {
        guard let id = flow.id else { return }
        do {
            _ = try databaseManager.queue.write { db in
                try Flow.deleteOne(db, key: id)
            }
            if selectedFlowID == id {
                selectedFlowID = nil
            }
            reload()
        } catch {
            log.error("Failed to delete flow: \(error.localizedDescription)")
            lastError = "Failed to delete flow: \(error.localizedDescription)"
        }
    }

    /// Persist edits to a flow's step tree (called by the editor in
    /// Phase 2 — left in place now so the skeleton compiles against
    /// the same API).
    func saveSteps(for flow: Flow, steps: [FlowStep]) {
        guard var updated = flows.first(where: { $0.id == flow.id }) else { return }
        updated.steps = steps   // setter bumps updatedAt
        do {
            try databaseManager.queue.write { db in
                try updated.update(db)
            }
            reload()
        } catch {
            log.error("Failed to save flow steps: \(error.localizedDescription)")
            lastError = "Failed to save flow: \(error.localizedDescription)"
        }
    }
}
