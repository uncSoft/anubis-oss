//
//  StepInspectorView.swift
//  anubis
//
//  Right-pane inspector. Switches on the selected FlowStepKind and
//  renders a compact editor per case. Edits route through
//  FlowEditorViewModel.updateSelectedStep so the single-channel
//  mutation pattern stays clean.
//
//  Editors are deliberately minimal in Phase 2 — enough to author a
//  meaningful flow end-to-end. Richer affordances (model picker with
//  thumbnails, prompt library browser, file bookmarks) can layer on
//  later without changing the data model.
//

import SwiftUI

struct StepInspectorView: View {
    @ObservedObject var editor: FlowEditorViewModel
    @ObservedObject var inferenceService: InferenceService

    var body: some View {
        Group {
            if let step = editor.selectedStep {
                content(for: step)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Select a step to edit its details")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Per-case content

    @ViewBuilder
    private func content(for step: FlowStep) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Header — name + icon.
            HStack(spacing: Spacing.xs) {
                Image(systemName: step.kind.iconName)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor))
                Text(step.kind.displayName)
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Body switches on the variant.
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    switch step.kind {
                    case .setBackend(let ref):
                        SetBackendEditor(ref: ref, inferenceService: inferenceService) { newRef in
                            editor.updateSelectedStep { s in
                                s.kind = .setBackend(newRef)
                            }
                        }
                    case .setModel(let name):
                        SetModelEditor(
                            name: name,
                            inferenceService: inferenceService,
                            impliedBackend: editor.steps.impliedBackend(beforeStepID: step.id)
                        ) { newName in
                            editor.updateSelectedStep { s in
                                s.kind = .setModel(newName)
                            }
                        }
                    case .setPrompt(let src):
                        SetPromptEditor(source: src) { newSrc in
                            editor.updateSelectedStep { s in
                                s.kind = .setPrompt(newSrc)
                            }
                        }
                    case .setParameters(let p):
                        SetParametersEditor(params: p) { newP in
                            editor.updateSelectedStep { s in
                                s.kind = .setParameters(newP)
                            }
                        }
                    case .runBenchmark:
                        runBenchmarkInfo
                    case .repeatN(let count, let body):
                        RepeatEditor(count: count, childCount: body.count) { newCount in
                            editor.updateSelectedStep { s in
                                if case .repeatN(_, let b) = s.kind {
                                    s.kind = .repeatN(count: newCount, body: b)
                                }
                            }
                        }
                    case .forEachModel(let models, _):
                        ForEachListEditor(
                            title: "Models",
                            placeholder: "llama3.2:3b",
                            values: models
                        ) { newValues in
                            editor.updateSelectedStep { s in
                                if case .forEachModel(_, let b) = s.kind {
                                    s.kind = .forEachModel(models: newValues, body: b)
                                }
                            }
                        }
                    case .forEachPrompt(let prompts, _):
                        ForEachListEditor(
                            title: "Prompts",
                            placeholder: "Write a haiku about Anubis",
                            values: prompts,
                            multiline: true
                        ) { newValues in
                            editor.updateSelectedStep { s in
                                if case .forEachPrompt(_, let b) = s.kind {
                                    s.kind = .forEachPrompt(prompts: newValues, body: b)
                                }
                            }
                        }
                    case .unloadModel:
                        unloadModelInfo
                    case .resetConnection:
                        resetConnectionInfo
                    case .coolDown(let mode):
                        CoolDownEditor(mode: mode) { newMode in
                            editor.updateSelectedStep { s in
                                s.kind = .coolDown(newMode)
                            }
                        }
                    case .annotate(let text):
                        AnnotateEditor(text: text) { newText in
                            editor.updateSelectedStep { s in
                                s.kind = .annotate(text: newText)
                            }
                        }
                    }
                }
                .padding(.bottom, Spacing.md)
            }
        }
        .padding(Spacing.md)
    }

    // MARK: - Inline informational panels

    private var runBenchmarkInfo: some View {
        infoPanel(
            icon: "info.circle",
            text: "Runs one benchmark using the backend, model, prompt, and parameters set by earlier steps. The resulting BenchmarkSession appears in the regular Run History, tagged with this flow run."
        )
    }

    private var unloadModelInfo: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            infoPanel(
                icon: "info.circle",
                text: "Asks Ollama to evict the current model from memory immediately. Useful between large models or before a cold-start measurement."
            )
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Ollama only — no-op on OpenAI-compatible and Apple Intelligence backends.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var resetConnectionInfo: some View {
        infoPanel(
            icon: "info.circle",
            text: "Tears down and rebuilds the URLSession for the current backend. Use after a server restart or to clear a wedged connection."
        )
    }

    private func infoPanel(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.sm)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: CornerRadius.sm))
    }
}

// MARK: - Per-case editors

private struct SetBackendEditor: View {
    let ref: FlowBackendRef
    @ObservedObject var inferenceService: InferenceService
    let onChange: (FlowBackendRef) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Backend").font(.subheadline.weight(.semibold))
            Picker("", selection: Binding(
                get: { ref.type },
                set: { newType in
                    let newConfigId: UUID?
                    if newType == .openai {
                        newConfigId = ref.openAIConfigId
                            ?? inferenceService.configManager.openAIConfigs.first?.id
                    } else {
                        newConfigId = nil
                    }
                    onChange(FlowBackendRef(type: newType, openAIConfigId: newConfigId))
                }
            )) {
                ForEach(InferenceBackendType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            if ref.type == .openai {
                Text("Server").font(.subheadline.weight(.semibold))
                Picker("", selection: Binding(
                    get: { ref.openAIConfigId },
                    set: { newId in
                        onChange(FlowBackendRef(type: .openai, openAIConfigId: newId))
                    }
                )) {
                    Text("(none)").tag(UUID?.none)
                    ForEach(inferenceService.configManager.openAIConfigs) { config in
                        Text(config.name).tag(Optional(config.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }
}

private struct SetModelEditor: View {
    let name: String
    @ObservedObject var inferenceService: InferenceService
    /// The backend implied by the nearest preceding Set Backend step,
    /// or nil if none. When non-nil we narrow the picker to that
    /// backend's models; nil falls back to "all models" with a hint.
    let impliedBackend: FlowBackendRef?
    let onChange: (String) -> Void

    @State private var draft: String = ""

    /// Models matching the implied backend. For OpenAI we additionally
    /// pin to the specific configured server.
    private var filteredModels: [ModelInfo] {
        guard let ref = impliedBackend else { return inferenceService.allModels }
        return inferenceService.allModels.filter { m in
            guard m.backend == ref.type else { return false }
            if ref.type == .openai, let configId = ref.openAIConfigId {
                return m.openAIConfigId == configId
            }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Model name").font(.subheadline.weight(.semibold))
            TextField("e.g. llama3.2:3b", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onAppear { draft = name }
                .onChange(of: draft) { _, new in onChange(new) }

            // Header for the picker list — shows which backend filter
            // is active so the user understands why the list looks
            // different from the Benchmark tab's model picker.
            HStack(spacing: 4) {
                if let ref = impliedBackend {
                    Image(systemName: ref.type.icon)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("Available on \(ref.type.displayName)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text("No Set Backend step before this — showing all")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.top, 2)

            if filteredModels.isEmpty {
                Text("No models loaded for this backend. Check that the server is running, then refresh in the Vault tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredModels.prefix(12)) { m in
                        Button {
                            draft = m.name
                        } label: {
                            HStack {
                                Image(systemName: m.backend.icon)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(m.name)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if filteredModels.count > 12 {
                        Text("+ \(filteredModels.count - 12) more — type to search")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                    }
                }
            }
        }
    }
}

private struct SetPromptEditor: View {
    let source: FlowPromptSource
    let onChange: (FlowPromptSource) -> Void

    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Prompt").font(.subheadline.weight(.semibold))
            TextEditor(text: $draft)
                .font(.system(.body))
                .frame(minHeight: 140)
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .onAppear {
                    if case .inline(let text) = source { draft = text }
                }
                .onChange(of: draft) { _, new in
                    onChange(.inline(text: new))
                }
            Text("Library and file sources arrive in Phase 5 — for now every prompt is inline text.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SetParametersEditor: View {
    let params: FlowParameters
    let onChange: (FlowParameters) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            paramRow("Temperature", value: params.temperature) { v in
                var p = params; p.temperature = v; onChange(p)
            } range: { 0...2 } format: { String(format: "%.2f", $0) }

            paramRow("Top-P", value: params.topP) { v in
                var p = params; p.topP = v; onChange(p)
            } range: { 0...1 } format: { String(format: "%.2f", $0) }

            HStack {
                Text("Max tokens").font(.caption)
                Spacer()
                TextField("", value: Binding(
                    get: { params.maxTokens },
                    set: { var p = params; p.maxTokens = $0; onChange(p) }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
            }

            Picker("Seed", selection: Binding(
                get: { params.seedStrategy },
                set: { var p = params; p.seedStrategy = $0; onChange(p) }
            )) {
                Text("Random").tag(SeedStrategy.random)
                Text("Fixed").tag(SeedStrategy.fixed)
            }
            .pickerStyle(.segmented)

            if params.seedStrategy == .fixed {
                HStack {
                    Text("Seed value").font(.caption)
                    Spacer()
                    TextField("", value: Binding(
                        get: { params.fixedSeed ?? 42 },
                        set: { var p = params; p.fixedSeed = $0; onChange(p) }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                }
            }
        }
    }

    private func paramRow(
        _ label: String,
        value: Double,
        update: @escaping (Double) -> Void,
        range: () -> ClosedRange<Double>,
        format: (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(format(value)).font(.system(.caption, design: .monospaced))
            }
            Slider(value: Binding(get: { value }, set: { update($0) }), in: range())
        }
    }
}

private struct RepeatEditor: View {
    let count: Int
    let childCount: Int
    let onChangeCount: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Stepper(value: Binding(
                get: { count },
                set: { onChangeCount(max(1, $0)) }
            ), in: 1...100) {
                Text("Repeat \(count)×").font(.subheadline.weight(.semibold))
            }
            Text("Runs the \(childCount) child step\(childCount == 1 ? "" : "s") \(count) times, captured as one BenchmarkRunGroup (mean ± 95% CI).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ForEachListEditor: View {
    let title: String
    let placeholder: String
    let values: [String]
    var multiline: Bool = false
    let onChange: ([String]) -> Void

    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title).font(.subheadline.weight(.semibold))

            ForEach(Array(values.enumerated()), id: \.offset) { idx, value in
                HStack {
                    Text("\(idx + 1).").font(.caption).foregroundStyle(.secondary)
                    Text(value)
                        .lineLimit(multiline ? 4 : 1)
                        .font(multiline ? .system(.body) : .system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        var copy = values
                        copy.remove(at: idx)
                        onChange(copy)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
                .padding(.vertical, 2)
            }

            HStack {
                if multiline {
                    TextEditor(text: $draft)
                        .frame(minHeight: 60)
                        .font(.system(.body))
                        .padding(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                } else {
                    TextField(placeholder, text: $draft)
                        .textFieldStyle(.roundedBorder)
                }
                Button {
                    addDraft()
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func addDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onChange(values + [trimmed])
        draft = ""
    }
}

private struct CoolDownEditor: View {
    let mode: CoolDownMode
    let onChange: (CoolDownMode) -> Void

    private enum ModeTag: String, CaseIterable { case thermal, fixed }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Picker("Mode", selection: Binding(
                get: { currentTag },
                set: { switchMode(to: $0) }
            )) {
                Text("Until thermal nominal").tag(ModeTag.thermal)
                Text("Fixed wait").tag(ModeTag.fixed)
            }
            .pickerStyle(.segmented)

            switch mode {
            case .thermal(let timeout):
                HStack {
                    Text("Safety timeout").font(.caption)
                    Spacer()
                    TextField("", value: Binding(
                        get: { timeout },
                        set: { onChange(.thermal(timeoutSeconds: max(10, $0))) }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    Text("seconds").font(.caption).foregroundStyle(.secondary)
                }
            case .fixed(let seconds):
                HStack {
                    Text("Wait").font(.caption)
                    Spacer()
                    TextField("", value: Binding(
                        get: { seconds },
                        set: { onChange(.fixed(seconds: max(1, $0))) }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    Text("seconds").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var currentTag: ModeTag {
        if case .thermal = mode { return .thermal }
        return .fixed
    }

    private func switchMode(to tag: ModeTag) {
        switch tag {
        case .thermal: onChange(.thermal(timeoutSeconds: 120))
        case .fixed: onChange(.fixed(seconds: 30))
        }
    }
}

private struct AnnotateEditor: View {
    let text: String
    let onChange: (String) -> Void

    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Note").font(.subheadline.weight(.semibold))
            TextEditor(text: $draft)
                .frame(minHeight: 100)
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .onAppear { draft = text }
                .onChange(of: draft) { _, new in onChange(new) }
            Text("Appears as a labeled marker in the flow report.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
