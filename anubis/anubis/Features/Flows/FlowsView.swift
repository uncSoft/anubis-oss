//
//  FlowsView.swift
//  anubis
//
//  Top-level view for the Flow Builder tab. Split layout: left sidebar
//  lists saved flows with new/rename/delete; right detail pane will
//  hold the drag-and-drop editor in Phase 2. For Phase 1 we render an
//  EmptyFlowEditorPlaceholder when a flow is selected so the wiring
//  end-to-end is testable without the editor's complexity.
//

import SwiftUI

struct FlowsView: View {
    @ObservedObject var inferenceService: InferenceService
    let databaseManager: DatabaseManager

    @StateObject private var viewModel: FlowsViewModel

    /// Drives the rename sheet for the row most recently right-clicked.
    @State private var renameTarget: Flow?
    @State private var renameDraft: String = ""

    /// When non-nil, the New Flow naming sheet is presented. Holding
    /// the draft as state on the parent keeps the sheet decoupled
    /// from the trigger button.
    @State private var newFlowDraft: String?

    init(inferenceService: InferenceService, databaseManager: DatabaseManager) {
        self.inferenceService = inferenceService
        self.databaseManager = databaseManager
        _viewModel = StateObject(wrappedValue: FlowsViewModel(databaseManager: databaseManager))
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            detail
                .frame(minWidth: 400)
        }
        .onAppear { viewModel.reload() }
        .sheet(item: $renameTarget) { flow in
            NameFlowSheet(
                title: "Rename Flow",
                confirmLabel: "Save",
                draft: $renameDraft,
                onConfirm: { newName in
                    viewModel.renameFlow(flow, to: newName)
                    renameTarget = nil
                },
                onCancel: { renameTarget = nil }
            )
        }
        .sheet(isPresented: Binding(
            get: { newFlowDraft != nil },
            set: { if !$0 { newFlowDraft = nil } }
        )) {
            NameFlowSheet(
                title: "New Flow",
                confirmLabel: "Create",
                draft: Binding(
                    get: { newFlowDraft ?? "" },
                    set: { newFlowDraft = $0 }
                ),
                onConfirm: { name in
                    viewModel.createFlow(name: name)
                    newFlowDraft = nil
                },
                onCancel: { newFlowDraft = nil }
            )
        }
    }

    /// Trigger the New Flow sheet with a sensible default name.
    private func presentNewFlowSheet() {
        // Suggest "Flow N" so the user doesn't have to think of a
        // name from scratch — they can accept, edit, or replace it.
        let n = viewModel.flows.count + 1
        newFlowDraft = "Flow \(n)"
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("My Flows")
                    .font(.headline)
                Spacer()
                Button {
                    presentNewFlowSheet()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Flow")
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)

            Divider()

            if viewModel.flows.isEmpty {
                emptySidebar
            } else {
                List(selection: $viewModel.selectedFlowID) {
                    ForEach(viewModel.flows) { flow in
                        FlowSidebarRow(flow: flow)
                            .tag(flow.id)
                            .contextMenu {
                                Button("Rename") {
                                    renameDraft = flow.name
                                    renameTarget = flow
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    viewModel.deleteFlow(flow)
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }

            if let err = viewModel.lastError {
                Divider()
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(Spacing.sm)
            }
        }
    }

    private var emptySidebar: some View {
        VStack(spacing: Spacing.sm) {
            Spacer()
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No flows yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("New Flow") { presentNewFlowSheet() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let flow = viewModel.selectedFlow {
            VStack(spacing: 0) {
                // Inline-editable name header sits above the editor so
                // renames don't require switching contexts.
                FlowDetailHeader(flow: flow) { newName in
                    viewModel.renameFlow(flow, to: newName)
                }
                Divider()
                FlowEditorView(
                    flow: flow,
                    parent: viewModel,
                    inferenceService: inferenceService
                )
                // Re-mount the editor (and reset its in-memory state)
                // whenever the selected flow changes.
                .id(flow.id)
            }
        } else {
            FlowsWelcomePane(onCreate: { presentNewFlowSheet() })
        }
    }
}

// MARK: - Sidebar row

private struct FlowSidebarRow: View {
    let flow: Flow

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(flow.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("\(flow.steps.count) step\(flow.steps.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Welcome pane (no flow selected)

private struct FlowsWelcomePane: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 64))
                .foregroundStyle(.tint.opacity(0.7))
            Text("Flow Builder")
                .font(.title.weight(.semibold))
            Text("Drag-and-drop sequencer for batch benchmark runs.\nChain backends, models, prompts, and repetitions — generate one report.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("New Flow") { onCreate() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, Spacing.sm)
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Detail header (inline rename)

private struct FlowDetailHeader: View {
    let flow: Flow
    let onRename: (String) -> Void

    /// Local editable copy of the name. We sync it from `flow.name`
    /// when the selection changes and push back to the viewmodel on
    /// submit/blur — debouncing every keystroke into a DB write would
    /// be wasteful for a string the user is actively typing.
    @State private var nameDraft: String = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            TextField("Flow name", text: $nameDraft)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .focused($nameFocused)
                .onSubmit { commitNameIfChanged() }
                .onChange(of: nameFocused) { _, focused in
                    if !focused { commitNameIfChanged() }
                }
            Spacer()
            // Static timestamp — no live second-by-second updates.
            // Refreshes naturally when the view re-renders after a save.
            Text("Updated \(flow.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .onAppear { nameDraft = flow.name }
        .onChange(of: flow.id) { _, _ in nameDraft = flow.name }
        .onChange(of: flow.name) { _, newName in
            // Reflect renames made elsewhere (e.g. sidebar context menu)
            // unless the user is actively editing the field.
            if !nameFocused { nameDraft = newName }
        }
    }

    private func commitNameIfChanged() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            nameDraft = flow.name
            return
        }
        if trimmed != flow.name {
            onRename(trimmed)
        }
    }
}

// MARK: - Name sheet (used by both New Flow and Rename Flow)

private struct NameFlowSheet: View {
    let title: String
    let confirmLabel: String
    @Binding var draft: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(title)
                .font(.headline)
            TextField("Flow name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .focused($fieldFocused)
                .onSubmit { submit() }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel) { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Spacing.lg)
        .onAppear {
            // Tiny delay so the sheet's transition completes before
            // focus moves into the field — without this the field
            // sometimes opens unfocused on macOS.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                fieldFocused = true
            }
        }
    }

    private func submit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed)
    }
}
