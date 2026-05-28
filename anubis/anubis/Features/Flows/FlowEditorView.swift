//
//  FlowEditorView.swift
//  anubis
//
//  Three-pane editor for a single Flow:
//    [ Palette ][   Step List   ][ Inspector ]
//
//  Palette: click a block to append it to the root (or to the
//  selected container's body).
//  Step List: recursive render with nested containers; click a row
//  to select; per-row Move Up/Down + Delete.
//  Inspector: per-case editor for whichever step is selected.
//
//  Drag-and-drop wiring lands in a follow-up — Phase 2's button-
//  driven add/move keeps the data-flow plumbing identical, so the
//  drag layer becomes purely view-side later.
//

import SwiftUI

struct FlowEditorView: View {
    @ObservedObject var parent: FlowsViewModel
    @ObservedObject var inferenceService: InferenceService
    let databaseManager: DatabaseManager
    let flow: Flow

    @StateObject private var editor: FlowEditorViewModel
    @StateObject private var executor: FlowExecutor

    /// Toggles the FlowRunView modal.
    @State private var isRunning: Bool = false

    init(
        flow: Flow,
        parent: FlowsViewModel,
        inferenceService: InferenceService,
        databaseManager: DatabaseManager
    ) {
        self.flow = flow
        self.parent = parent
        self.inferenceService = inferenceService
        self.databaseManager = databaseManager
        _editor = StateObject(wrappedValue: FlowEditorViewModel(flow: flow, parent: parent))
        _executor = StateObject(wrappedValue: FlowExecutor(
            inferenceService: inferenceService,
            databaseManager: databaseManager
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                FlowStepPalette { kind in
                    addStep(kind: kind)
                }
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)

                // Step list defaults narrower now — the row content
                // (icon + title + summary + chevrons) fits in ~280pt,
                // and the freed pixels go to the inspector where
                // textareas and sliders actually benefit from width.
                FlowStepListView(editor: editor)
                    .frame(minWidth: 240, idealWidth: 280)

                StepInspectorView(
                    editor: editor,
                    inferenceService: inferenceService
                )
                .frame(minWidth: 340, idealWidth: 440, maxWidth: 600)
            }
        }
        .sheet(isPresented: $isRunning) {
            FlowRunView(executor: executor, flow: editor.flow) {
                // Close button — only enabled once the executor leaves
                // .running, so this is safe.
                isRunning = false
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Text(flow.name)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            if editor.isDirty {
                Text("Unsaved")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text("\(editor.steps.count) step\(editor.steps.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Total expected Run Benchmark invocations across the flow,
            // multiplied through repeatN / forEach containers.
            let runs = editor.steps.expectedRunCount
            HStack(spacing: 4) {
                Image(systemName: "number.circle.fill")
                Text("\(runs) run\(runs == 1 ? "" : "s")")
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color.accentColor.opacity(runs > 0 ? 0.18 : 0.06))
            )
            .foregroundStyle(runs > 0 ? Color.accentColor : Color.secondary)
            .help(runs > 0
                  ? "This flow will produce \(runs) BenchmarkSession\(runs == 1 ? "" : "s")"
                  : "Add a Run Benchmark step (optionally inside Repeat or For Each) to make this flow produce sessions")
            Button("Discard") { editor.discard() }
                .disabled(!editor.isDirty)
            Button("Save") { editor.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!editor.isDirty)
            Button {
                runFlow()
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(editor.steps.isEmpty || editor.steps.expectedRunCount == 0)
            .help(runHelpText)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    /// Tooltip + accessibility label for the Run button, reflecting
    /// the most informative reason it's disabled (if any).
    private var runHelpText: String {
        if editor.steps.isEmpty {
            return "Add at least one step to run this flow"
        }
        if editor.steps.expectedRunCount == 0 {
            return "Add a Run Benchmark step (optionally inside Repeat or For Each)"
        }
        if editor.isDirty {
            return "Saves and runs the flow"
        }
        return "Run flow"
    }

    /// Persist any pending edits, then kick off the executor and
    /// surface the run sheet. Auto-save means the FlowRun snapshot
    /// always reflects what the user just saw in the editor.
    private func runFlow() {
        if editor.isDirty { editor.save() }
        executor.start(flow: editor.flow)
        isRunning = true
    }

    // MARK: - Add target resolution

    /// If the user has a container selected, add inside it. Otherwise
    /// append at the root. Matches Shortcuts.app behaviour.
    private func addStep(kind: FlowStepKind) {
        if let selID = editor.selectedStepID,
           let path = editor.path(forID: selID),
           let selectedStep = editor.steps.step(at: path),
           selectedStep.kind.isContainer {
            editor.appendInside(containerPath: path, kind: kind)
        } else {
            editor.appendToRoot(kind: kind)
        }
    }
}

// MARK: - Palette

struct FlowStepPalette: View {
    let onPick: (FlowStepKind) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                section(title: "State", items: [
                    (.setBackend(.init(type: .ollama, openAIConfigId: nil)), "Set Backend"),
                    (.setModel(""), "Set Model"),
                    (.setPrompt(.inline(text: "")), "Set Prompt"),
                    (.setParameters(.default), "Set Parameters"),
                ])

                section(title: "Action", items: [
                    (.runBenchmark, "Run Benchmark"),
                    (.repeatN(count: 3, body: []), "Repeat"),
                    (.forEachModel(models: [], body: []), "For Each Model"),
                    (.forEachPrompt(prompts: [], body: []), "For Each Prompt"),
                ])

                section(title: "Management", items: [
                    (.unloadModel, "Unload Model"),
                    (.resetConnection, "Reset Connection"),
                    (.coolDown(.thermal(timeoutSeconds: 120)), "Cool Down"),
                    (.annotate(text: ""), "Annotate"),
                ])
            }
            .padding(Spacing.sm)
        }
    }

    private func section(title: String, items: [(FlowStepKind, String)]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.xs)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                PaletteItemButton(kind: item.0, label: item.1, onPick: onPick)
            }
        }
    }
}

private struct PaletteItemButton: View {
    let kind: FlowStepKind
    let label: String
    let onPick: (FlowStepKind) -> Void

    var body: some View {
        Button {
            onPick(kind)
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: kind.iconName)
                    .frame(width: 18)
                    .foregroundStyle(.tint)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: CornerRadius.sm))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step list (recursive)

struct FlowStepListView: View {
    @ObservedObject var editor: FlowEditorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if editor.steps.isEmpty {
                    emptyState
                } else {
                    FlowStepListLevel(
                        steps: editor.steps,
                        editor: editor,
                        parentPath: []
                    )
                }
            }
            .padding(Spacing.sm)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "hand.point.left")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Pick a block from the palette to add your first step.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xxl)
    }
}

/// One level of the step tree. Recurses for container bodies.
private struct FlowStepListLevel: View {
    let steps: [FlowStep]
    @ObservedObject var editor: FlowEditorViewModel
    let parentPath: FlowStepPath

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                let path: FlowStepPath = parentPath + [idx]
                FlowStepRow(
                    step: step,
                    path: path,
                    siblingCount: steps.count,
                    editor: editor
                )

                if step.kind.isContainer, let children = step.kind.children {
                    // Nested body — indented, with its own children list +
                    // a footer "+ Add inside" hint.
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        if children.isEmpty {
                            Text("Empty — select this container, then click a palette block.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                                .padding(.leading, Spacing.sm)
                        } else {
                            FlowStepListLevel(
                                steps: children,
                                editor: editor,
                                parentPath: path
                            )
                        }
                    }
                    .padding(.leading, Spacing.lg)
                    .overlay(alignment: .leading) {
                        // Visual nesting guide.
                        Rectangle()
                            .fill(Color.tint.opacity(0.25))
                            .frame(width: 2)
                            .padding(.leading, Spacing.xs)
                    }
                }
            }
        }
    }
}

// MARK: - Step row

private struct FlowStepRow: View {
    let step: FlowStep
    let path: FlowStepPath
    let siblingCount: Int
    @ObservedObject var editor: FlowEditorViewModel

    private var isSelected: Bool { editor.selectedStepID == step.id }
    private var siblingIndex: Int { path.last ?? 0 }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: step.kind.iconName)
                .frame(width: 22, height: 22)
                .foregroundStyle(isSelected ? Color.white : Color.tint)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? Color.tint : Color.tint.opacity(0.15))
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(step.kind.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(step.kind.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Reorder + delete controls. Compact, fade in on hover
            // would be nicer but stays-visible keeps macOS native.
            HStack(spacing: 2) {
                Button {
                    editor.moveSibling(at: path, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(siblingIndex <= 0)
                .help("Move Up")

                Button {
                    editor.moveSibling(at: path, by: +1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(siblingIndex >= siblingCount - 1)
                .help("Move Down")

                Button {
                    editor.delete(at: path)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Delete")
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.sm)
                .fill(isSelected ? Color.tint.opacity(0.12) : Color.gray.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.sm)
                .strokeBorder(isSelected ? Color.tint.opacity(0.7) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            editor.selectedStepID = step.id
        }
        .contextMenu {
            Button("Delete", role: .destructive) {
                editor.delete(at: path)
            }
        }
    }
}

// MARK: - Step kind summary (one-line description for the row)

extension FlowStepKind {
    /// One-line subtitle shown under the step's display name in rows.
    /// Stays terse; richer editing happens in the inspector.
    var summary: String {
        switch self {
        case .setBackend(let ref):
            if ref.type == .openai, ref.openAIConfigId != nil {
                return "OpenAI Compatible (configured)"
            }
            return ref.type.displayName
        case .setModel(let name):
            return name.isEmpty ? "(no model)" : name
        case .setPrompt(let src):
            switch src {
            case .inline(let text):
                return text.isEmpty ? "(empty)" : text.prefix(60) + (text.count > 60 ? "…" : "")
            case .library(let id):
                return "Library: \(id)"
            case .file(_, let name):
                return "File: \(name)"
            }
        case .setParameters(let p):
            return String(
                format: "temp %.2f · top-p %.2f · max %d",
                p.temperature, p.topP, p.maxTokens
            )
        case .runBenchmark:
            return "Capture one BenchmarkSession with current context"
        case .repeatN(let count, let body):
            return "\(count)× · \(body.count) child step\(body.count == 1 ? "" : "s")"
        case .forEachModel(let models, _):
            return models.isEmpty ? "(no models)" : "\(models.count) model\(models.count == 1 ? "" : "s")"
        case .forEachPrompt(let prompts, _):
            return prompts.isEmpty ? "(no prompts)" : "\(prompts.count) prompt\(prompts.count == 1 ? "" : "s")"
        case .unloadModel:
            return "Ollama only — POST /api/generate keep_alive=0"
        case .resetConnection:
            return "Rebuild backend URLSession"
        case .coolDown(let mode):
            switch mode {
            case .thermal(let s): return "Until thermal nominal (timeout \(s)s)"
            case .fixed(let s): return "Wait \(s)s"
            }
        case .annotate(let text):
            return text.isEmpty ? "(empty note)" : text
        }
    }
}

// Convenience to extend an IndexPath by appending a single index.
private func + (lhs: IndexPath, rhs: [Int]) -> IndexPath {
    var p = lhs
    for v in rhs { p.append(v) }
    return p
}

// Project tint color shorthand used above. Falls back to .accentColor
// where the named color is unavailable.
private extension Color {
    static var tint: Color { .accentColor }
}
