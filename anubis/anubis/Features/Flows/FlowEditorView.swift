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

/// Shared animation for any structural change to the step tree
/// (reorder / add / delete). Subtle enough that bulk edits aren't
/// punishing, fluid enough that the user can track which row moved.
let stepEditAnimation: Animation = .easeInOut(duration: 0.22)

struct FlowEditorView: View {
    @ObservedObject var parent: FlowsViewModel
    @ObservedObject var inferenceService: InferenceService
    let databaseManager: DatabaseManager
    let flow: Flow

    @StateObject private var editor: FlowEditorViewModel
    @StateObject private var executor: FlowExecutor

    /// Toggles the FlowRunView modal.
    @State private var isRunning: Bool = false

    /// Drives the warnings popover anchored to the header chip.
    @State private var showingWarningsPopover: Bool = false

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
            FlowRunView(
                executor: executor,
                flow: editor.flow,
                databaseManager: databaseManager
            ) {
                // Close button — only enabled once the executor leaves
                // .running, so this is safe. Also tell the parent
                // viewmodel to refetch — the executor inserts a new
                // FlowRun row directly via the DB queue, bypassing
                // every FlowsViewModel mutator, so without this hook
                // the sidebar's Run History silently stays stale
                // (and stays empty after a Clear All History).
                isRunning = false
                parent.reload()
            }
        }
        // Pick up the FlowRun row as soon as the executor inserts it
        // (state → .running) and again when it finalizes (status icon
        // change in the sidebar). Cheap; the reload is a single
        // ordered fetch.
        .onChange(of: executor.state) { _, newState in
            switch newState {
            case .running, .completed, .failed, .cancelled:
                parent.reload()
            case .idle:
                break
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

            // Lint chip — clickable when there's anything to surface.
            let allWarnings = editor.steps.lintWarnings()
            if !allWarnings.isEmpty {
                warningsChip(allWarnings)
            }

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

    /// Yellow header chip showing the lint count. Tap to open a popover
    /// listing every warning with a "Reveal" jump-to-step button.
    private func warningsChip(_ warnings: [FlowWarning]) -> some View {
        Button {
            showingWarningsPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("\(warnings.count) warning\(warnings.count == 1 ? "" : "s")")
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.orange.opacity(0.18)))
            .foregroundStyle(Color.orange)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingWarningsPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Flow Warnings")
                    .font(.headline)
                Text("These won't block the run, but are likely mistakes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                ForEach(warnings) { w in
                    Button {
                        editor.selectedStepID = w.stepID
                        showingWarningsPopover = false
                    } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                            Text(w.message)
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .padding(Spacing.md)
            .frame(width: 360)
        }
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
    /// append at the root. Matches Shortcuts.app behaviour. Wrapped
    /// in withAnimation so the new row eases in rather than popping.
    private func addStep(kind: FlowStepKind) {
        withAnimation(stepEditAnimation) {
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

    @State private var isHovering: Bool = false

    var body: some View {
        // NOTE: must NOT be a Button. macOS SwiftUI's Button gesture
        // eats the mouse-down before .draggable can convert it into
        // a drag session — leaving the click working but the drag
        // never engaging. Same .onTapGesture + .draggable pattern as
        // FlowStepRow, which is why rows have always been draggable.
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
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.sm)
                .fill(isHovering ? Color.gray.opacity(0.16) : Color.gray.opacity(0.08))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            onPick(kind)
        }
        // Drag a new step from the palette into the step list. Click
        // still appends; drag offers precise placement.
        .draggable(FlowDragPayload(source: .newStep(kind: kind))) {
            HStack(spacing: 6) {
                Image(systemName: kind.iconName)
                Text(label).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.85), in: Capsule())
            .foregroundStyle(.white)
        }
    }
}

// MARK: - Drop zone

/// Thin horizontal target slot that appears between rows (and at the
/// end of each list level). Invisible at rest; lights up with an
/// accent capsule while a drag is hovering. On drop, routes the
/// payload to the editor — palette payload inserts a fresh step,
/// existing-step payload moves the step to this slot.
struct FlowDropZone: View {
    let targetPath: FlowStepPath
    @ObservedObject var editor: FlowEditorViewModel

    @State private var isTargeted: Bool = false

    var body: some View {
        Capsule()
            .fill(isTargeted ? Color.accentColor : Color.clear)
            .frame(height: isTargeted ? 4 : 3)
            .padding(.horizontal, Spacing.xs)
            .contentShape(Rectangle().inset(by: -4)) // generous hit area
            .dropDestination(for: FlowDragPayload.self) { payloads, location in
                print("[DragDrop] DropZone action fired — path=\(Array(targetPath)) payloadCount=\(payloads.count) location=\(location)")
                guard let payload = payloads.first else {
                    print("[DragDrop]   no payloads — drop refused")
                    return false
                }
                print("[DragDrop]   payload.source=\(payload.source)")
                withAnimation(stepEditAnimation) {
                    switch payload.source {
                    case .newStep(let kind):
                        print("[DragDrop]   inserting new \(kind.displayName) at \(Array(targetPath))")
                        editor.insertNewStep(kind: kind, at: targetPath)
                    case .existingStep(let id):
                        print("[DragDrop]   moving existing \(id) to \(Array(targetPath))")
                        editor.moveStep(id: id, to: targetPath)
                    }
                }
                return true
            } isTargeted: { hovering in
                print("[DragDrop] DropZone isTargeted=\(hovering) path=\(Array(targetPath))")
                withAnimation(.easeInOut(duration: 0.10)) {
                    isTargeted = hovering
                }
            }
    }
}

// MARK: - Step list (recursive)

struct FlowStepListView: View {
    @ObservedObject var editor: FlowEditorViewModel

    /// Lint results keyed by step id. Recomputed cheaply on every body
    /// rebuild (the walker is O(n) and the editor only re-renders on
    /// mutations anyway).
    private var warnings: [UUID: [FlowWarning]] {
        editor.steps.lintWarningsByStepID()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if editor.steps.isEmpty {
                    emptyState
                } else {
                    FlowStepListLevel(
                        steps: editor.steps,
                        editor: editor,
                        parentPath: [],
                        warnings: warnings
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

/// One level of the step tree. Recurses for container bodies. Each
/// row is preceded by a FlowDropZone for the insertion slot above it,
/// and a final zone caps the bottom of the level so users can drop
/// at the end without precision-aiming the last row.
private struct FlowStepListLevel: View {
    let steps: [FlowStep]
    @ObservedObject var editor: FlowEditorViewModel
    let parentPath: FlowStepPath
    let warnings: [UUID: [FlowWarning]]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                let path: FlowStepPath = parentPath + [idx]

                FlowDropZone(targetPath: path, editor: editor)

                FlowStepRow(
                    step: step,
                    path: path,
                    siblingCount: steps.count,
                    editor: editor,
                    warnings: warnings[step.id] ?? []
                )

                if step.kind.isContainer, let children = step.kind.children {
                    // Nested body — indented, with its own children list +
                    // a drop zone for "append inside" when the body's empty.
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        if children.isEmpty {
                            // Empty container: a single drop zone takes
                            // the place of the prior "click a palette
                            // block" hint, so users can drag right in.
                            FlowContainerEmptyDropZone(
                                containerPath: path,
                                editor: editor
                            )
                        } else {
                            FlowStepListLevel(
                                steps: children,
                                editor: editor,
                                parentPath: path,
                                warnings: warnings
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
            // Trailing drop zone — append to this level.
            FlowDropZone(
                targetPath: parentPath + [steps.count],
                editor: editor
            )
        }
    }
}

/// Specialised drop target shown when a container has no children
/// yet. Same payload handling as a regular FlowDropZone but with a
/// hint label and a slightly bigger hit area, since this is the
/// user's *first* introduction to "drop here to fill the body".
private struct FlowContainerEmptyDropZone: View {
    let containerPath: FlowStepPath
    @ObservedObject var editor: FlowEditorViewModel

    @State private var isTargeted: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 11))
            Text("Drag a palette block here, or select this container and click one.")
                .font(.caption)
        }
        .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
        .padding(.vertical, 6)
        .padding(.horizontal, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.sm)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.gray.opacity(0.3),
                    style: StrokeStyle(lineWidth: 1, dash: [4])
                )
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.sm)
                        .fill(isTargeted ? Color.accentColor.opacity(0.10) : Color.clear)
                )
        )
        .dropDestination(for: FlowDragPayload.self) { payloads, location in
            print("[DragDrop] EmptyContainerDrop action fired — container=\(Array(containerPath)) payloadCount=\(payloads.count) location=\(location)")
            guard let payload = payloads.first else {
                print("[DragDrop]   no payloads — drop refused")
                return false
            }
            print("[DragDrop]   payload.source=\(payload.source)")
            // Drop into an empty body means insert at index 0 of that body.
            let target = containerPath + [0]
            withAnimation(stepEditAnimation) {
                switch payload.source {
                case .newStep(let kind):
                    print("[DragDrop]   inserting new \(kind.displayName) at \(Array(target))")
                    editor.insertNewStep(kind: kind, at: target)
                case .existingStep(let id):
                    print("[DragDrop]   moving existing \(id) to \(Array(target))")
                    editor.moveStep(id: id, to: target)
                }
            }
            return true
        } isTargeted: { hovering in
            print("[DragDrop] EmptyContainerDrop isTargeted=\(hovering) container=\(Array(containerPath))")
            withAnimation(.easeInOut(duration: 0.10)) {
                isTargeted = hovering
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
    let warnings: [FlowWarning]

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
                HStack(spacing: 4) {
                    Text(step.kind.displayName)
                        .font(.system(size: 13, weight: .medium))
                    if !warnings.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .help(warnings.map { $0.message }.joined(separator: "\n"))
                    }
                }
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
                    withAnimation(stepEditAnimation) {
                        editor.moveSibling(at: path, by: -1)
                    }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(siblingIndex <= 0)
                .help("Move Up")

                Button {
                    withAnimation(stepEditAnimation) {
                        editor.moveSibling(at: path, by: +1)
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(siblingIndex >= siblingCount - 1)
                .help("Move Down")

                Button {
                    withAnimation(stepEditAnimation) {
                        editor.delete(at: path)
                    }
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
                .strokeBorder(borderColor, lineWidth: borderColor == .clear ? 0 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            editor.selectedStepID = step.id
        }
        .contextMenu {
            Button("Delete", role: .destructive) {
                withAnimation(stepEditAnimation) {
                    editor.delete(at: path)
                }
            }
        }
        // Drag to reorder. The chevrons still work for keyboard-style
        // adjustment; drag is for precise placement across nesting.
        .draggable(FlowDragPayload(source: .existingStep(id: step.id))) {
            // Compact drag preview — same icon + name, no controls.
            HStack(spacing: 6) {
                Image(systemName: step.kind.iconName)
                Text(step.kind.displayName)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.85), in: Capsule())
            .foregroundStyle(.white)
        }
    }

    /// Border highlight priority: selection (blue) beats warning
    /// (yellow) beats nothing. Selected-and-warned rows still show
    /// the tooltip on the inline icon.
    private var borderColor: Color {
        if isSelected { return Color.tint.opacity(0.7) }
        if !warnings.isEmpty { return Color.orange.opacity(0.55) }
        return .clear
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
