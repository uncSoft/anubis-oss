//
//  FlowEditorViewModel.swift
//  anubis
//
//  Holds the in-memory editing state for one Flow: the working
//  copy of `steps`, the currently-selected step id, and a dirty
//  flag. Mutations route through the tree primitives in
//  Flow.swift; saving pushes the working copy through the parent
//  FlowsViewModel so the DB write goes through a single channel.
//

import Foundation
import Combine

@MainActor
final class FlowEditorViewModel: ObservableObject {
    // MARK: - Published State

    /// Working copy of the flow's step tree. Bound by all editor UI.
    @Published var steps: [FlowStep]

    /// Currently selected step (drives the right-pane inspector).
    @Published var selectedStepID: UUID?

    /// True once any mutation is applied that has not yet been saved.
    @Published private(set) var isDirty: Bool = false

    // MARK: - Dependencies

    /// The owning flow at the time the editor opened. Used to send
    /// saves back through the parent and to detect when the user
    /// switches to a different flow.
    private(set) var flow: Flow
    private let parent: FlowsViewModel

    // MARK: - Init

    init(flow: Flow, parent: FlowsViewModel) {
        self.flow = flow
        self.parent = parent
        self.steps = flow.steps
    }

    // MARK: - Mutations

    /// Append a new step to the root level.
    func appendToRoot(kind: FlowStepKind) {
        let step = FlowStep(kind: kind)
        steps.append(step)
        selectedStepID = step.id
        markDirty()
    }

    /// Append a new step to the body of a container.
    func appendInside(containerPath path: FlowStepPath, kind: FlowStepKind) {
        guard let container = steps.step(at: path),
              container.kind.isContainer else { return }
        let childCount = container.kind.children?.count ?? 0
        var insertPath = path
        insertPath.append(childCount)
        let step = FlowStep(kind: kind)
        steps.insertStep(step, at: insertPath)
        selectedStepID = step.id
        markDirty()
    }

    /// Delete a step (and its subtree if it's a container).
    func delete(at path: FlowStepPath) {
        let removed = steps.removeStep(at: path)
        if let removedID = removed?.id, selectedStepID == removedID {
            selectedStepID = nil
        }
        markDirty()
    }

    /// Move a step up or down within its parent.
    func moveSibling(at path: FlowStepPath, by delta: Int) {
        steps.moveSibling(at: path, by: delta)
        markDirty()
    }

    /// Update the currently-selected step in place.
    func updateSelectedStep(_ transform: (inout FlowStep) -> Void) {
        guard let id = selectedStepID,
              let path = steps.path(forID: id) else { return }
        steps.updateStep(at: path, transform)
        markDirty()
    }

    /// Update an arbitrary step by id.
    func updateStep(id: UUID, _ transform: (inout FlowStep) -> Void) {
        guard let path = steps.path(forID: id) else { return }
        steps.updateStep(at: path, transform)
        markDirty()
    }

    // MARK: - Lookup

    /// Path to a step by id, or nil if not found.
    func path(forID id: UUID) -> FlowStepPath? {
        steps.path(forID: id)
    }

    /// The currently selected step, if any.
    var selectedStep: FlowStep? {
        guard let id = selectedStepID,
              let path = steps.path(forID: id) else { return nil }
        return steps.step(at: path)
    }

    // MARK: - Save / Discard

    /// Persist the working copy through the parent view model.
    func save() {
        parent.saveSteps(for: flow, steps: steps)
        // Pick up the saved flow (so updatedAt reflects DB state on
        // the header) — the parent already reloaded its list.
        if let refreshed = parent.flows.first(where: { $0.id == flow.id }) {
            flow = refreshed
        }
        isDirty = false
    }

    /// Discard local changes and revert to the on-disk flow.
    func discard() {
        steps = flow.steps
        selectedStepID = nil
        isDirty = false
    }

    // MARK: - Internal

    private func markDirty() {
        isDirty = true
    }
}
