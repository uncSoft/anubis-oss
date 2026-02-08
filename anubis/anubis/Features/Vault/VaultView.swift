//
//  VaultView.swift
//  anubis
//
//  Created on 2026-01-26.
//

import SwiftUI

/// Model management and inspection view
struct VaultView: View {
    @StateObject private var viewModel: VaultViewModel
    @State private var searchText = ""
    @State private var filterBackend: InferenceBackendType?

    init(inferenceService: InferenceService) {
        _viewModel = StateObject(wrappedValue: VaultViewModel(inferenceService: inferenceService))
    }

    private var filteredModels: [ModelInfo] {
        var result = viewModel.models

        // Filter by backend
        if let backend = filterBackend {
            result = result.filter { $0.backend == backend }
        }

        // Filter by search
        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                ($0.family?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }

        return result
    }

    var body: some View {
        HSplitView {
            // Left panel - Model List
            modelListPanel
                .frame(minWidth: 300, idealWidth: 350, maxWidth: 450)

            // Right panel - Model Inspector
            if let model = viewModel.selectedModel {
                ModelInspectorView(
                    model: model,
                    detailedInfo: viewModel.detailedInfo,
                    isLoading: viewModel.isLoadingInfo,
                    isRunning: viewModel.isModelRunning(model),
                    backendURL: viewModel.backendURL(for: model),
                    onUnload: { Task { await viewModel.unloadModel(model) } },
                    onDelete: { viewModel.confirmDelete(model) }
                )
                .frame(minWidth: 400)
            } else {
                emptyInspector
                    .frame(minWidth: 400)
            }
        }
        .navigationTitle("Vault")
        .toolbar {
            ToolbarItemGroup {
                // Pull new model
                Button {
                    viewModel.startPull()
                } label: {
                    Label("Pull Model", systemImage: "arrow.down.circle")
                }

                // Refresh
                Button {
                    Task { await viewModel.loadModels() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoadingModels)
            }
        }
        .task {
            await viewModel.loadModels()
        }
        .sheet(isPresented: $viewModel.showPullSheet) {
            PullModelSheet(viewModel: viewModel)
        }
        .confirmationDialog(
            "Delete Model?",
            isPresented: $viewModel.showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await viewModel.deleteModel() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let model = viewModel.modelToDelete {
                Text("This will permanently delete \"\(model.name)\" (\(model.formattedSize)). This cannot be undone.")
            }
        }
    }

    // MARK: - Model List Panel

    private var modelListPanel: some View {
        VStack(spacing: 0) {
            // Search and filter bar
            HStack(spacing: Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search models...", text: $searchText)
                    .textFieldStyle(.plain)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(Spacing.sm)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: CornerRadius.md))
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.md)

            // Filter chips
            HStack(spacing: Spacing.xs) {
                FilterChip(label: "All", isSelected: filterBackend == nil) {
                    filterBackend = nil
                }
                FilterChip(
                    label: "Ollama (\(viewModel.ollamaModelCount))",
                    isSelected: filterBackend == .ollama
                ) {
                    filterBackend = .ollama
                }
                FilterChip(
                    label: "MLX (\(viewModel.mlxModelCount))",
                    isSelected: filterBackend == .mlx
                ) {
                    filterBackend = .mlx
                }
                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)

            Divider()

            // Running models indicator
            if !viewModel.runningModels.isEmpty {
                runningModelsSection
                Divider()
            }

            // Model list
            if viewModel.isLoadingModels && viewModel.models.isEmpty {
                ProgressView("Loading models...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredModels.isEmpty {
                emptyModelList
            } else {
                List(filteredModels, selection: Binding(
                    get: { viewModel.selectedModel },
                    set: { viewModel.selectModel($0) }
                )) { model in
                    ModelRow(
                        model: model,
                        isRunning: viewModel.isModelRunning(model)
                    )
                    .tag(model)
                }
                .listStyle(.inset)
            }

            // Status bar
            statusBar
        }
    }

    private var runningModelsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.green)
                Text("Loaded Models")
                    .font(.caption.bold())
                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.xs)

            ForEach(viewModel.runningModels) { running in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(running.name)
                            .font(.caption)
                            .lineLimit(1)
                        Text("\(Formatters.bytes(running.sizeVRAM)) VRAM")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let expires = running.expiresAt {
                        Text(Formatters.relativeDate(expires))
                            .font(.caption2)
                            .foregroundStyle(running.isExpiringSoon ? .orange : .secondary)
                    }

                    Button {
                        Task { await viewModel.unloadRunningModel(running) }
                    } label: {
                        Image(systemName: "eject.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Unload from memory")
                }
                .padding(.horizontal, Spacing.md)
            }
            .padding(.bottom, Spacing.xs)
        }
        .background(.green.opacity(0.05))
    }

    private var emptyModelList: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(searchText.isEmpty ? "No models found" : "No matching models")
                .foregroundStyle(.secondary)
            if searchText.isEmpty {
                Text("Pull a model to get started")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack {
            Text("\(filteredModels.count) models")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Text("Total: \(Formatters.bytes(viewModel.totalDiskUsage))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .background(.bar)
    }

    private var emptyInspector: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Select a model to inspect")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Model Row

struct ModelRow: View {
    let model: ModelInfo
    let isRunning: Bool

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // Backend icon
            Image(systemName: model.backend.icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(model.name)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if isRunning {
                        Circle()
                            .fill(Color.anubisSuccess)
                            .frame(width: 6, height: 6)
                            .shadow(color: Color.anubisSuccess.opacity(0.5), radius: 2)
                    }
                }

                HStack(spacing: Spacing.xs) {
                    if let family = model.family {
                        Text(family)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background {
                                Capsule()
                                    .fill(Color.cardBackground)
                                    .overlay {
                                        Capsule()
                                            .strokeBorder(Color.cardBorder, lineWidth: 0.5)
                                    }
                            }
                    }

                    Text(model.formattedSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let params = model.parameterCount {
                        Text(Formatters.parameterCount(params))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let quant = model.quantization {
                        Text(quant)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, Spacing.xs)
        .contentShape(Rectangle())
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background {
                    Capsule()
                        .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.cardBackground)
                        .overlay {
                            Capsule()
                                .strokeBorder(
                                    isSelected ? Color.accentColor.opacity(0.5) : Color.cardBorder,
                                    lineWidth: 1
                                )
                        }
                }
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Model Inspector

struct ModelInspectorView: View {
    let model: ModelInfo
    let detailedInfo: OllamaModelInfo?
    let isLoading: Bool
    let isRunning: Bool
    var backendURL: String = "—"
    let onUnload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                // Header
                headerSection

                Divider()

                // Basic Info
                basicInfoSection

                // Detailed Info (Ollama only)
                if model.backend == .ollama {
                    if isLoading {
                        ProgressView("Loading details...")
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else if let info = detailedInfo {
                        detailedInfoSection(info)
                    }
                }

                // Actions
                actionsSection
            }
            .padding(Spacing.lg)
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Image(systemName: model.backend.icon)
                    .font(.title2)
                    .foregroundStyle(.secondary)

                Text(model.name)
                    .font(.title2.bold())

                if isRunning {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("Loaded")
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.green.opacity(0.15), in: Capsule())
                }
            }

            HStack(spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: 1) {
                    Label(model.backend.displayName, systemImage: model.backend.icon)
                    Text(backendURL)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let date = model.modifiedAt {
                    Label(Formatters.relativeDate(date), systemImage: "clock")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: Spacing.md) {
                InfoCell(title: "Size", value: model.formattedSize)
                InfoCell(title: "Parameters", value: model.formattedParameters)
                InfoCell(title: "Quantization", value: model.quantization ?? "—")
                InfoCell(title: "Family", value: model.family ?? "—")
                InfoCell(title: "Context", value: model.contextLength.map { "\($0)" } ?? "—")
                InfoCell(title: "Backend", value: model.backend.displayName)
            }

            if let path = model.path {
                HStack {
                    Text("Path")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .padding(.top, Spacing.sm)
            }
        }
    }

    private func detailedInfoSection(_ info: OllamaModelInfo) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Model Architecture")
                .font(.headline)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: Spacing.md) {
                if let arch = info.architecture {
                    InfoCell(title: "Architecture", value: arch)
                }
                if let ctx = info.contextLength {
                    InfoCell(title: "Max Context", value: "\(ctx)")
                }
                if let emb = info.embeddingLength {
                    InfoCell(title: "Embedding Dim", value: "\(emb)")
                }
                if let blocks = info.blockCount {
                    InfoCell(title: "Layers", value: "\(blocks)")
                }
                if let heads = info.headCount {
                    InfoCell(title: "Attention Heads", value: "\(heads)")
                }
                if let kvHeads = info.kvHeadCount {
                    InfoCell(title: "KV Heads", value: "\(kvHeads)")
                }
                if let vocab = info.vocabSize {
                    InfoCell(title: "Vocab Size", value: Formatters.number(vocab))
                }
                if let rope = info.ropeFreqBase {
                    InfoCell(title: "RoPE Base", value: Formatters.number(Int(rope)))
                }
            }

            // Template
            if let template = info.template, !template.isEmpty {
                DisclosureGroup {
                    Text(template)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.sm)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: CornerRadius.md))
                } label: {
                    Text("Chat Template")
                        .font(.headline)
                }
            }

            // Parameters
            if let params = info.parameters, !params.isEmpty {
                DisclosureGroup {
                    Text(params)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.sm)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: CornerRadius.md))
                } label: {
                    Text("Model Parameters")
                        .font(.headline)
                }
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Actions")
                .font(.headline)

            HStack(spacing: Spacing.sm) {
                if isRunning && model.backend == .ollama {
                    Button(action: onUnload) {
                        Label("Unload", systemImage: "eject.fill")
                    }
                    .buttonStyle(.bordered)
                }

                if model.backend == .ollama {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

// MARK: - Info Cell

struct InfoCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.mono(14, weight: .medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .metricCardStyle()
    }
}

// MARK: - Pull Model Sheet

struct PullModelSheet: View {
    @ObservedObject var viewModel: VaultViewModel

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Text("Pull Model")
                .font(.headline)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Model Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("e.g. llama3.2:3b", text: $viewModel.pullModelName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.isPulling)
            }

            if viewModel.isPulling {
                VStack(spacing: Spacing.sm) {
                    ProgressView(value: viewModel.pullProgress)
                        .progressViewStyle(.linear)

                    Text(viewModel.pullStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if viewModel.pullProgress > 0 {
                        Text("\(Int(viewModel.pullProgress * 100))%")
                            .font(.mono(14, weight: .medium))
                    }
                }
            }

            HStack {
                Button("Cancel") {
                    viewModel.cancelPull()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Pull") {
                    Task { await viewModel.pullModel() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.pullModelName.isEmpty || viewModel.isPulling)
                .keyboardShortcut(.return, modifiers: [])
            }

            // Common models suggestion
            if !viewModel.isPulling {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Popular Models")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: Spacing.xs) {
                        ModelSuggestionButton("llama3.2:3b") { viewModel.pullModelName = $0 }
                        ModelSuggestionButton("qwen2.5:7b") { viewModel.pullModelName = $0 }
                        ModelSuggestionButton("deepseek-r1:8b") { viewModel.pullModelName = $0 }
                        ModelSuggestionButton("phi4:14b") { viewModel.pullModelName = $0 }
                    }
                }
            }
        }
        .padding(Spacing.lg)
        .frame(width: 400)
    }
}

struct ModelSuggestionButton: View {
    let name: String
    let action: (String) -> Void

    init(_ name: String, action: @escaping (String) -> Void) {
        self.name = name
        self.action = action
    }

    var body: some View {
        Button(name) {
            action(name)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
