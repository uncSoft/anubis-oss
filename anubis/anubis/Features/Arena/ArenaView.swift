//
//  ArenaView.swift
//  anubis
//
//  Created on 2026-01-26.
//

import SwiftUI

/// Main Arena view for side-by-side model comparison
struct ArenaView: View {
    @StateObject private var viewModel: ArenaViewModel
    @State private var showingHistory = false
    @State private var showingModelManager = false
    @State private var showSystemPrompt = false
    @State private var showParameters = false

    init(
        appState: AppState,
        inferenceService: InferenceService,
        metricsService: MetricsService,
        databaseManager: DatabaseManager
    ) {
        _viewModel = StateObject(wrappedValue: ArenaViewModel(
            appState: appState,
            inferenceService: inferenceService,
            metricsService: metricsService,
            databaseManager: databaseManager
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top controls
            controlsSection

            // Error banner
            if let error = viewModel.error {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        viewModel.forceReset()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss error")
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(Color.anubisError.opacity(0.1))
            }

            Divider()

            // Main content - side by side comparison
            HSplitView {
                // Model A panel
                ComparisonPanel(
                    label: "A",
                    color: .blue,
                    backend: $viewModel.backendA,
                    selectedModel: $viewModel.modelA,
                    openAIConfig: $viewModel.openAIConfigA,
                    availableModels: viewModel.modelsForBackendA,
                    openAIConfigs: viewModel.configManager.openAIConfigs,
                    backendDisplayName: viewModel.backendADisplayName,
                    backendURL: viewModel.backendAURL,
                    response: viewModel.responseA,
                    session: viewModel.sessionA,
                    debugState: viewModel.debugStateA,
                    isRunning: viewModel.isRunning,
                    isWinner: viewModel.currentComparison?.winner == .modelA,
                    totalElapsedTime: viewModel.elapsedTimeA,
                    onSelectBackend: { backend in
                        viewModel.backendA = backend
                        viewModel.openAIConfigA = nil
                        viewModel.modelA = viewModel.modelsForBackendA.first
                    },
                    onSelectOpenAI: { config in
                        viewModel.setOpenAIBackendA(config)
                    }
                )

                // Model B panel
                ComparisonPanel(
                    label: "B",
                    color: .orange,
                    backend: $viewModel.backendB,
                    selectedModel: $viewModel.modelB,
                    openAIConfig: $viewModel.openAIConfigB,
                    availableModels: viewModel.modelsForBackendB,
                    openAIConfigs: viewModel.configManager.openAIConfigs,
                    backendDisplayName: viewModel.backendBDisplayName,
                    backendURL: viewModel.backendBURL,
                    response: viewModel.responseB,
                    session: viewModel.sessionB,
                    debugState: viewModel.debugStateB,
                    isRunning: viewModel.isRunning,
                    isWinner: viewModel.currentComparison?.winner == .modelB,
                    totalElapsedTime: viewModel.elapsedTimeB,
                    onSelectBackend: { backend in
                        viewModel.backendB = backend
                        viewModel.openAIConfigB = nil
                        viewModel.modelB = viewModel.modelsForBackendB.first
                    },
                    onSelectOpenAI: { config in
                        viewModel.setOpenAIBackendB(config)
                    }
                )
            }

            // Bottom - voting and status
            if viewModel.sessionA != nil && viewModel.sessionB != nil {
                votingSection
            }
        }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showingModelManager.toggle()
                } label: {
                    Label("Models", systemImage: "memorychip")
                }
                .popover(isPresented: $showingModelManager) {
                    ModelManagerPopover(viewModel: viewModel)
                }
            }

            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showingHistory.toggle()
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                if viewModel.isRunning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)

                        Text(viewModel.currentPhase)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Button(action: viewModel.stopComparison) {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)

                        Button(action: viewModel.forceReset) {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Force Reset")
                    }
                } else {
                    HStack(spacing: 8) {
                        if viewModel.error != nil {
                            Button(action: viewModel.forceReset) {
                                Label("Reset", systemImage: "arrow.counterclockwise")
                            }
                            .buttonStyle(.bordered)
                        }

                        Button(action: viewModel.startComparison) {
                            Label("Compare", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.canStart)
                    }
                }
            }
        }
        .sheet(isPresented: $showingHistory) {
            ArenaHistoryView(viewModel: viewModel)
        }
        .task {
            await viewModel.loadModels()
            await viewModel.loadRecentComparisons()
        }
        .onChange(of: viewModel.backendA) { _, _ in
            viewModel.modelA = viewModel.modelsForBackendA.first
        }
        .onChange(of: viewModel.backendB) { _, _ in
            viewModel.modelB = viewModel.modelsForBackendB.first
        }
    }

    // MARK: - Controls Section

    private var controlsSection: some View {
        VStack(spacing: Spacing.md) {
            // Execution mode selector
            HStack {
                Text("Execution Mode:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Mode", selection: $viewModel.executionMode) {
                    Text("Sequential (Memory-Safe)").tag(ArenaExecutionMode.sequential)
                    Text("Parallel (Simultaneous Run)").tag(ArenaExecutionMode.parallel)
                }
                .pickerStyle(.segmented)
                .frame(width: 350)

                Spacer()

                if viewModel.executionMode == .parallel {
                    Text("Est. Memory: \(viewModel.estimatedMemoryUsage)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Prompt input
            VStack(alignment: .leading, spacing: Spacing.xs) {
                // System prompt (collapsible)
                DisclosureGroup(isExpanded: $showSystemPrompt) {
                    TextEditor(text: $viewModel.systemPrompt)
                        .font(.body)
                        .frame(height: 50)
                        .scrollContentBackground(.hidden)
                        .padding(Spacing.xs)
                        .background {
                            RoundedRectangle(cornerRadius: CornerRadius.md)
                                .fill(Color.cardBackground)
                                .overlay {
                                    RoundedRectangle(cornerRadius: CornerRadius.md)
                                        .strokeBorder(Color.cardBorder, lineWidth: 1)
                                }
                        }
                        .disabled(viewModel.isRunning)
                } label: {
                    HStack {
                        Text("System Prompt")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !viewModel.systemPrompt.isEmpty {
                            Text("(\(viewModel.systemPrompt.count) chars)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { showSystemPrompt.toggle() }
                }

                // Generation parameters (collapsible)
                DisclosureGroup(isExpanded: $showParameters) {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        // Temperature
                        HStack {
                            Text("Temperature")
                                .font(.caption)
                                .frame(width: 80, alignment: .leading)
                            Slider(value: $viewModel.temperature, in: 0...2, step: 0.1)
                                .frame(width: 200)
                            Text(String(format: "%.1f", viewModel.temperature))
                                .font(.mono(11, weight: .medium))
                                .frame(width: 40, alignment: .trailing)
                        }

                        // Top-P
                        HStack {
                            Text("Top-P")
                                .font(.caption)
                                .frame(width: 80, alignment: .leading)
                            Slider(value: $viewModel.topP, in: 0...1, step: 0.05)
                                .frame(width: 200)
                            Text(String(format: "%.2f", viewModel.topP))
                                .font(.mono(11, weight: .medium))
                                .frame(width: 40, alignment: .trailing)
                        }

                        // Max Tokens
                        HStack {
                            Text("Max Tokens")
                                .font(.caption)
                                .frame(width: 80, alignment: .leading)
                            Slider(value: Binding(
                                get: { Double(viewModel.maxTokens) },
                                set: { viewModel.maxTokens = Int($0) }
                            ), in: 256...8192, step: 256)
                                .frame(width: 200)
                            Text("\(viewModel.maxTokens)")
                                .font(.mono(11, weight: .medium))
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Spacing.xs)
                    .disabled(viewModel.isRunning)
                } label: {
                    HStack {
                        Text("Parameters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("T:\(String(format: "%.1f", viewModel.temperature)) P:\(String(format: "%.1f", viewModel.topP)) Tokens:\(viewModel.maxTokens)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { showParameters.toggle() }
                }

                // Main prompt
                HStack {
                    Text("Prompt")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    // Preset prompt selector
                    Menu {
                        ForEach(BenchmarkPrompt.PromptCategory.allCases, id: \.self) { category in
                            if let prompts = BenchmarkPrompt.presetsByCategory[category] {
                                Section(category.rawValue) {
                                    ForEach(prompts) { preset in
                                        Button {
                                            viewModel.prompt = preset.prompt
                                        } label: {
                                            HStack {
                                                Text(preset.name)
                                                Spacer()
                                                Text(preset.expectedLength.rawValue)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "text.badge.star")
                            Text("Presets")
                        }
                        .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(viewModel.isRunning)
                }

                TextEditor(text: $viewModel.prompt)
                    .font(.body)
                    .frame(height: 80)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.xs)
                    .background {
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .fill(Color.cardBackground)
                            .overlay {
                                RoundedRectangle(cornerRadius: CornerRadius.md)
                                    .strokeBorder(Color.cardBorder, lineWidth: 1)
                            }
                    }
                    .disabled(viewModel.isRunning)
            }
        }
        .padding(Spacing.md)
    }

    // MARK: - Voting Section

    private var votingSection: some View {
        HStack(spacing: Spacing.lg) {
            Spacer()

            Text("Winner:")
                .font(.headline)

            VotingButton(
                label: "Model A",
                color: .blue,
                isSelected: viewModel.currentComparison?.winner == .modelA
            ) {
                Task { await viewModel.setWinner(.modelA) }
            }

            VotingButton(
                label: "Tie",
                color: .gray,
                isSelected: viewModel.currentComparison?.winner == .tie,
                showDot: false
            ) {
                Task { await viewModel.setWinner(.tie) }
            }

            VotingButton(
                label: "Model B",
                color: .orange,
                isSelected: viewModel.currentComparison?.winner == .modelB
            ) {
                Task { await viewModel.setWinner(.modelB) }
            }

            Spacer()
        }
        .padding(Spacing.md)
        .background(.bar)
    }
}

// MARK: - Comparison Panel

struct ComparisonPanel: View {
    let label: String
    let color: Color
    @Binding var backend: InferenceBackendType
    @Binding var selectedModel: ModelInfo?
    @Binding var openAIConfig: BackendConfiguration?
    let availableModels: [ModelInfo]
    let openAIConfigs: [BackendConfiguration]
    let backendDisplayName: String
    let backendURL: String
    let response: String
    let session: BenchmarkSession?
    let debugState: DebugInspectorState
    let isRunning: Bool
    let isWinner: Bool
    let totalElapsedTime: TimeInterval?
    let onSelectBackend: (InferenceBackendType) -> Void
    let onSelectOpenAI: (BackendConfiguration) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Circle()
                    .fill(color)
                    .frame(width: 16, height: 16)
                    .overlay {
                        Text(label)
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                    }

                // Backend selector menu
                Menu {
                    Section("Local") {
                        Button {
                            onSelectBackend(.ollama)
                        } label: {
                            HStack {
                                Text("Ollama")
                                if backend == .ollama { Image(systemName: "checkmark") }
                            }
                        }
                    }

                    if !openAIConfigs.isEmpty {
                        Section("OpenAI-Compatible") {
                            ForEach(openAIConfigs) { config in
                                Button {
                                    onSelectOpenAI(config)
                                } label: {
                                    HStack {
                                        Text(config.name)
                                        if backend == .openai && openAIConfig?.id == config.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(backendDisplayName)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                        Text(backendURL)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(isRunning)

                Picker("Model", selection: $selectedModel) {
                    if availableModels.isEmpty {
                        Text("No models").tag(nil as ModelInfo?)
                    } else {
                        ForEach(availableModels) { model in
                            Text(model.name).tag(model as ModelInfo?)
                        }
                    }
                }
                .labelsHidden()
                .disabled(isRunning)

                Spacer()

                if isWinner {
                    Image(systemName: "trophy.fill")
                        .foregroundStyle(.yellow)
                }
            }
            .padding(Spacing.sm)
            .background(color.opacity(0.1))

            Divider()

            // Response + stats wrapped in debug panel (bar at bottom, expands upward)
            DebugInspectorPanel(debugState: debugState, accentColor: color) {
                VStack(spacing: 0) {
                    StreamingTextView(
                        text: response,
                        placeholder: "Response will appear here..."
                    )

                    // Stats footer
                    if let session = session {
                        Divider()
                        sessionStatsFooter(session)
                    }
                }
            }
        }
        .frame(minWidth: 350)
    }

    private func sessionStatsFooter(_ session: BenchmarkSession) -> some View {
        let isOllama = backend == .ollama

        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Session Details")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)


            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: Spacing.xs) {
                // Avg Tokens/sec
                DetailStatCell(
                    title: "Avg Tokens/sec",
                    value: session.tokensPerSecond.map { Formatters.tokensPerSecond($0) } ?? "—"
                )

                // Time to First Token
                DetailStatCell(
                    title: "Time to First Token",
                    value: session.timeToFirstToken.map { Formatters.milliseconds($0 * 1000) } ?? "—"
                )

                // Avg Token Latency
                DetailStatCell(
                    title: "Avg Token Latency",
                    value: session.averageTokenLatencyMs.map { Formatters.milliseconds($0) } ?? "—"
                )

                // Completion Tokens
                DetailStatCell(
                    title: "Completion Tokens",
                    value: session.completionTokens.map { "\($0)" } ?? "—"
                )

                // Prompt Tokens
                DetailStatCell(
                    title: "Prompt Tokens",
                    value: session.promptTokens.map { "\($0)" } ?? "—"
                )

                // Total Duration
                DetailStatCell(
                    title: "Total Duration",
                    value: totalElapsedTime.map { Formatters.duration($0) } ?? "—"
                )

                // Model Load Time (Ollama only)
                DetailStatCell(
                    title: "Model Load Time",
                    value: isOllama
                        ? (session.loadDuration.map { Formatters.duration($0) } ?? "—")
                        : "N/A"
                )

                // Eval Duration (Ollama only)
                DetailStatCell(
                    title: "Eval Duration",
                    value: isOllama
                        ? (session.evalDuration.map { Formatters.duration($0) } ?? "—")
                        : "N/A"
                )

                // Context Length (Ollama only)
                DetailStatCell(
                    title: "Context Length",
                    value: isOllama
                        ? (session.contextLength.map { "\($0) tokens" } ?? "—")
                        : "N/A"
                )
            }
        }
        .padding(Spacing.md)
        .background {
            RoundedRectangle(cornerRadius: CornerRadius.lg)
                .fill(Color.cardBackgroundElevated)
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.lg)
                        .strokeBorder(Color.cardBorder, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        }
    }
}

// MARK: - Stat Pill

struct StatPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.mono(11, weight: .medium))
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background {
            RoundedRectangle(cornerRadius: CornerRadius.sm)
                .fill(Color.cardBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.sm)
                        .strokeBorder(Color.cardBorder, lineWidth: 0.5)
                }
        }
    }
}

// MARK: - Model Manager Popover

struct ModelManagerPopover: View {
    @ObservedObject var viewModel: ArenaViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("Loaded Models")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await viewModel.refreshRunningModels() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            if viewModel.runningModels.isEmpty {
                Text("No models currently loaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                ForEach(viewModel.runningModels) { model in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.name)
                                .font(.body)
                            Text(Formatters.bytes(model.sizeVRAM) + " VRAM")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Unload") {
                            Task { await viewModel.unloadModel(model) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, Spacing.xs)
                }
            }

            Divider()

            Button("Unload All") {
                Task { await viewModel.unloadAllModels() }
            }
            .disabled(viewModel.runningModels.isEmpty)
        }
        .padding(Spacing.md)
        .frame(width: 300)
    }
}

// MARK: - Arena History View

struct ArenaHistoryView: View {
    @ObservedObject var viewModel: ArenaViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedComparison: ArenaComparisonResult?

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Comparison History")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(Spacing.md)
            .background(.bar)

            Divider()

            if viewModel.recentComparisons.isEmpty {
                VStack(spacing: Spacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: CornerRadius.lg)
                            .fill(Color.emptyStateBackground)
                            .overlay {
                                RoundedRectangle(cornerRadius: CornerRadius.lg)
                                    .strokeBorder(Color.cardBorder, lineWidth: 1)
                            }
                            .frame(width: 120, height: 100)
                        Image(systemName: "square.split.2x1")
                            .font(.system(size: 40))
                            .foregroundStyle(.quaternary)
                    }
                    Text("No comparisons yet")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Run a comparison to see results here")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.recentComparisons, id: \.comparison.id) { result in
                    ComparisonRow(result: result)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

// MARK: - Comparison Row

struct ComparisonRow: View {
    let result: ArenaComparisonResult

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                // Model A
                HStack(spacing: 4) {
                    Circle().fill(.blue).frame(width: 8, height: 8)
                    Text(result.sessionA.modelName)
                        .lineLimit(1)
                }
                .foregroundStyle(result.comparison.winner == .modelA ? .primary : .secondary)

                Text("vs")
                    .foregroundStyle(.tertiary)

                // Model B
                HStack(spacing: 4) {
                    Circle().fill(.orange).frame(width: 8, height: 8)
                    Text(result.sessionB.modelName)
                        .lineLimit(1)
                }
                .foregroundStyle(result.comparison.winner == .modelB ? .primary : .secondary)

                Spacer()

                // Winner badge
                if let winner = result.comparison.winner {
                    WinnerBadge(winner: winner)
                } else {
                    Text("No vote")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Text(result.comparison.prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack {
                Text(result.comparison.executionMode)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background {
                        Capsule()
                            .fill(Color.cardBackground)
                            .overlay {
                                Capsule()
                                    .strokeBorder(Color.cardBorder, lineWidth: 0.5)
                            }
                    }

                Spacer()

                Text(Formatters.relativeDate(result.comparison.createdAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}

// MARK: - Voting Button

struct VotingButton: View {
    let label: String
    let color: Color
    let isSelected: Bool
    var showDot: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if showDot {
                    Circle()
                        .fill(color)
                        .frame(width: 12, height: 12)
                }
                Text(label)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(
                isSelected ? color.opacity(0.2) : Color.clear,
                in: RoundedRectangle(cornerRadius: CornerRadius.md)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .strokeBorder(color.opacity(0.3), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Winner Badge

struct WinnerBadge: View {
    let winner: ArenaWinner

    var body: some View {
        HStack(spacing: 4) {
            if winner != .tie {
                Image(systemName: "trophy.fill")
                    .font(.caption2)
            }
            Text(winnerText)
        }
        .badgeStyle(color: winnerColor)
    }

    private var winnerText: String {
        switch winner {
        case .modelA: return "A Wins"
        case .modelB: return "B Wins"
        case .tie: return "Tie"
        }
    }

    private var winnerColor: Color {
        switch winner {
        case .modelA: return .blue
        case .modelB: return .orange
        case .tie: return .gray
        }
    }
}
