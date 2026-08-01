//
//  BenchmarkView.swift
//  anubis
//
//  Created on 2026-01-25.
//

import SwiftUI
import Charts
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Export Mode Environment Key

private struct IsExportingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isExporting: Bool {
        get { self[IsExportingKey.self] }
        set { self[IsExportingKey.self] = newValue }
    }
}

/// Main benchmark dashboard view
struct BenchmarkView: View {
    // Observed (not owned) — the VM lives in AppState so it survives tab
    // navigation: a running benchmark keeps running and the last results stay.
    @ObservedObject private var viewModel: BenchmarkViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var showSystemPrompt = false
    // Persisted, default expanded — so new users see the N-runs +
    // Thinking-toggle controls at least once. Once they collapse
    // these, the preference sticks across launches.
    @AppStorage(Constants.UserDefaultsKeys.benchmarkParametersExpanded) private var showParameters: Bool = true
    @AppStorage(Constants.UserDefaultsKeys.benchmarkPerformanceExpanded) private var showPerformance: Bool = true
    @State private var showSessionDetails = true
    /// Session Details source override. nil = follow the default (show oMLX's
    /// own metrics whenever the run has them); once the user picks a side it
    /// sticks across runs. Keyed off the run carrying server-reported metrics.
    @State private var detailsSourceOverride: Bool? = nil
    @State private var showLeaderboardUpload = false
    @State private var showThinkingHelp = false

    init(viewModel: BenchmarkViewModel) {
        self.viewModel = viewModel
    }

    /// True-black dashboard canvas with a faint accent glow in the top-trailing
    /// corner — gives the metrics dashboard a modern, dark "web3" feel while
    /// keeping charcoal cards readable against it.
    private var dashboardBackdrop: some View {
        ZStack {
            Color.dashboardBackground
            RadialGradient(
                colors: [Color.anubisAccent.opacity(0.10), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 480
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    var body: some View {
        HSplitView {
            // Left panel - Controls and Response
            VStack(spacing: 0) {
                controlsSection
                Divider()
                DebugInspectorPanel(debugState: viewModel.debugState) {
                    responseSection
                }
            }
            .frame(minWidth: 400, maxWidth: 700)
            .background(Color.dashboardBackground)

            // Right panel - Metrics Dashboard (~70% default)
            ScrollView {
                VStack(spacing: Spacing.sm) {
                    groupProgressBanner
                    groupSummaryCard
                    metricsCardsSection
                    detailedStatsSection
                    chartsSection
                }
                .padding(Spacing.sm)
            }
            .frame(minWidth: 300)
            .layoutPriority(1)
            .background(dashboardBackdrop)
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button {
                        copyToClipboard()
                    } label: {
                        Label("Copy to Clipboard", systemImage: "doc.on.doc")
                    }
                    .keyboardShortcut("c", modifiers: .command)

                    Button {
                        saveAsPNG()
                    } label: {
                        Label("Save as PNG…", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        shareImage()
                    } label: {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }

                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export benchmark results")

                LeaderboardPillButton(viewModel: viewModel, showLeaderboardUpload: $showLeaderboardUpload)

                Button {
                    viewModel.openExpandedMetricsWindow()
                } label: {
                    Label("Expand Results", systemImage: "arrow.up.left.and.arrow.down.right")
                        .symbolEffect(.pulse, isActive: viewModel.isRunning)
                }
                .help("Expand metrics dashboard")

                Button {
                    viewModel.openHistoryWindow()
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }

                Button {
                    if viewModel.selectedBackend == .ollama {
                        viewModel.openBrowseLibrary()
                    } else {
                        viewModel.openOMLXBrowser()
                    }
                } label: {
                    Label("Browse Models", systemImage: "books.vertical")
                }
                .help("Browse and download models (Ollama registry / oMLX HuggingFace)")
                .disabled(!(viewModel.selectedBackend == .ollama
                            || viewModel.isBuiltInOMLXBackend
                            || viewModel.isVerifiedOMLX))

                Button {
                    viewModel.startPull()
                } label: {
                    Label("Pull Model", systemImage: "arrow.down.circle")
                }
                .help("Pull a model from Ollama by name")
                .disabled(viewModel.selectedBackend != .ollama)
            }
        }
        .onDisappear {
            viewModel.closeAuxiliaryWindows()
        }
        .sheet(isPresented: $showLeaderboardUpload) {
            if let session = viewModel.currentSession {
                LeaderboardUploadView(
                    session: session,
                    group: viewModel.currentRunGroup,
                    // While the group is mid-run, currentRepetitionIndex
                    // is the 1-based active rep. After completion it's
                    // reset to 0, in which case currentSession is the
                    // most recent (last) rep — use completedRepetitions
                    // for that index.
                    repetitionIndex: viewModel.currentRepetitionIndex > 0
                        ? viewModel.currentRepetitionIndex
                        : viewModel.currentRunGroup?.completedRepetitions,
                    onSubmitted: { viewModel.markCurrentSessionLeaderboardSubmitted() }
                )
            }
        }
        .sheet(isPresented: $viewModel.showPullSheet) {
            BenchmarkPullModelSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showBrowseLibrarySheet) {
            BrowseOllamaLibrarySheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showOMLXBrowserSheet) {
            OMLXModelBrowserSheet(viewModel: viewModel)
        }
        .task {
            await viewModel.loadInitialDataIfNeeded()
        }
        .onChange(of: viewModel.selectedBackend) { _, _ in
            Task {
                await viewModel.loadModels()
            }
        }
    }

    // MARK: - Export

    private var exportableContent: some View {
        VStack(spacing: Spacing.md) {
            metricsCardsSection
            detailedStatsSection
            chartsSection
        }
        .padding(Spacing.md)
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 4) {
                if let appIcon = NSApp.applicationIconImage {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                Text("anubis by JT")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.primary)
            .opacity(0.4)
            .padding(.bottom, Spacing.md)
            .padding(.trailing, Spacing.lg)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @MainActor
    private func renderImage() -> NSImage? {
        let content = exportableContent
            .frame(width: 1100)
            .environment(\.colorScheme, colorScheme)
            .environment(\.isExporting, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2.0
        return renderer.nsImage
    }

    private func copyToClipboard() {
        guard let image = renderImage() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    private func saveAsPNG() {
        guard let image = renderImage(),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else { return }

        let modelSlug = (viewModel.selectedModel?.name ?? viewModel.currentSession?.modelName ?? "benchmark")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let defaultName = "anubis-\(modelSlug)-\(timestamp).png"

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? pngData.write(to: url)
    }

    private func shareImage() {
        guard let image = renderImage() else { return }
        guard let contentView = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [image])
        let anchorRect = NSRect(x: contentView.bounds.maxX - 40, y: contentView.bounds.maxY - 40, width: 1, height: 1)
        picker.show(relativeTo: anchorRect, of: contentView, preferredEdge: .minY)
    }

    // MARK: - Controls Section

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Model Selection
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    Text("Model")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Show current backend as badge
                    Text(viewModel.selectedBackend.displayName)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            Capsule()
                                .fill(Color.cardBackground)
                                .overlay {
                                    Capsule()
                                        .strokeBorder(Color.cardBorder, lineWidth: 0.5)
                                }
                        }

                    Text(viewModel.connectionURL)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                HStack(spacing: Spacing.md) {
                    Picker("Model", selection: $viewModel.selectedModel) {
                        if viewModel.availableModels.isEmpty {
                            Text("No models available").tag(nil as ModelInfo?)
                        } else {
                            ForEach(viewModel.availableModels) { model in
                                Text(model.name).tag(model as ModelInfo?)
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .frame(minWidth: 300, alignment: .leading)

                    Spacer()

                    // Eject (unload) the selected model — Ollama and oMLX.
                    if viewModel.canEjectSelectedModel {
                        Button {
                            Task { await viewModel.ejectSelectedModel() }
                        } label: {
                            if viewModel.isEjectingModel {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "eject.fill")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(viewModel.isEjectingModel || viewModel.isRunning)
                        .help("Unload the selected model from memory")
                    }

                    // Refresh models button
                    Button {
                        Task { await viewModel.loadModels() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh model list")
                }

                if let notice = viewModel.ejectNotice {
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }

            // System Prompt (collapsible)
            DisclosureGroup(isExpanded: $showSystemPrompt) {
                TextEditor(text: $viewModel.systemPrompt)
                    .font(.body)
                    .frame(height: 60)
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

                    Divider()
                        .padding(.vertical, 2)

                    // Repetitions — N≥2 creates a BenchmarkRunGroup so
                    // the result is mean ± 95% bootstrap CI instead of
                    // a single number that hides variance.
                    HStack {
                        Text("Repetitions")
                            .font(.caption)
                            .frame(width: 80, alignment: .leading)
                        Stepper(value: $viewModel.repetitions, in: 1...20) {
                            EmptyView()
                        }
                        .labelsHidden()
                        Text("\(viewModel.repetitions)")
                            .font(.mono(11, weight: .medium))
                            .frame(width: 40, alignment: .trailing)
                        Text(viewModel.repetitions > 1
                             ? "× mean ± 95% CI"
                             : "(single run)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    // Seed strategy — only meaningful when Repetitions > 1.
                    // Random (default) lets the CI capture sampler noise;
                    // Fixed isolates hardware-only variance.
                    if viewModel.repetitions > 1 {
                        HStack {
                            Text("Seed")
                                .font(.caption)
                                .frame(width: 80, alignment: .leading)
                            Picker("", selection: $viewModel.seedStrategy) {
                                Text("Random per rep").tag(SeedStrategy.random)
                                Text("Fixed").tag(SeedStrategy.fixed)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 200)
                            if viewModel.seedStrategy == .fixed {
                                TextField("seed", value: $viewModel.fixedSeed, format: .number)
                                    .font(.mono(11))
                                    .frame(width: 80)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Spacing.xs)
                .disabled(viewModel.isRunning)
            } label: {
                HStack {
                    Text("Parameters/N Runs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("T:\(String(format: "%.1f", viewModel.temperature)) P:\(String(format: "%.1f", viewModel.topP)) Tokens:\(viewModel.maxTokens)\(viewModel.repetitions > 1 ? " · n=\(viewModel.repetitions)" : "")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { showParameters.toggle() }
            }

            // Prompt Input
            VStack(alignment: .leading, spacing: Spacing.xs) {
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
                                            viewModel.promptText = preset.prompt
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

                TextEditor(text: $viewModel.promptText)
                    .font(.body)
                    .frame(height: 100)
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

            // Action Bar
            HStack {
                // Start/Stop Button
                if viewModel.isRunning {
                    Button(action: viewModel.stopBenchmark) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button(action: viewModel.startBenchmark) {
                        Label("Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.selectedModel == nil)
                }

                // Status indicator
                if viewModel.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Running...")
                        .foregroundStyle(.secondary)
                } else if let session = viewModel.currentSession, session.status == .completed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Completed")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(viewModel.formattedElapsedTime)
                    .font(.mono(14, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if let error = viewModel.error {
                HStack(alignment: .top, spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.anubisWarning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(error.localizedDescription)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        if let suggestion = error.recoverySuggestion {
                            Text(suggestion)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .fill(Color.anubisWarning.opacity(0.1))
                        .overlay {
                            RoundedRectangle(cornerRadius: CornerRadius.md)
                                .strokeBorder(Color.anubisWarning.opacity(0.3), lineWidth: 1)
                        }
                }
            }

            // Performance toggles (collapsible)
            DisclosureGroup(isExpanded: $showPerformance) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.md) {
                        Toggle(isOn: $viewModel.streamResponse) {
                            Text("Stream Response")
                                .font(.caption)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(viewModel.isRunning)

                        Toggle(isOn: $viewModel.showLiveCharts) {
                            Text("Live Charts")
                                .font(.caption)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }

                    // Thinking toggle. Ollama uses the `think` field; oMLX uses
                    // chat_template_kwargs.enable_thinking. Default `Auto` omits
                    // it (safest for models/servers that reject the field).
                    if viewModel.supportsThinkingToggle {
                        HStack(spacing: Spacing.sm) {
                            Text("Thinking")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button {
                                showThinkingHelp.toggle()
                            } label: {
                                Image(systemName: "info.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showThinkingHelp, arrowEdge: .bottom) {
                                thinkingHelpPopover
                            }
                            Picker("", selection: $viewModel.ollamaThinkMode) {
                                ForEach(OllamaThinkMode.allCases, id: \.self) { mode in
                                    Text(mode.displayLabel).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .controlSize(.small)
                            .frame(maxWidth: 220)
                            .labelsHidden()
                            .disabled(viewModel.isRunning)
                            .help("Auto: omit the `think` field (model default — safest for older Ollama versions or non-thinking models). On: send think:true to force reasoning. Off: send think:false to disable it.")
                            Spacer()
                        }
                    }
                }
                .padding(.top, Spacing.xxs)
            } label: {
                HStack {
                    Text("Performance/Thinking")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !viewModel.streamResponse
                        || !viewModel.showLiveCharts
                        || (viewModel.supportsThinkingToggle && viewModel.ollamaThinkMode != .auto) {
                        Text("modified")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { showPerformance.toggle() }
            }
        }
        .padding(Spacing.md)
    }

    // MARK: - Response Section

    private var responseSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Response")
                    .font(.headline)
                if let session = viewModel.currentSession,
                   session.status == .completed,
                   session.evalDuration != nil {
                    InferenceStatsButton(session: session)
                    // Surface thermal contamination on the row itself, not only
                    // behind the stats popover — a run recorded under pressure
                    // is not comparable to one at nominal.
                    if session.ranUnderThermalPressure {
                        Image(systemName: "thermometer.high")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                            .help("Ran under thermal pressure — not comparable to a run at nominal.")
                    }
                    if session.hitTokenCap {
                        Image(systemName: "scissors")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .help("Generation stopped at the max_tokens cap rather than finishing on its own.")
                    }
                }
                Spacer()
                Text(Formatters.tokens(viewModel.tokensGenerated))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.md)

            if !viewModel.streamResponse && viewModel.isRunning {
                // Lightweight placeholder when response rendering is suppressed
                HStack {
                    Spacer()
                    VStack(spacing: Spacing.xs) {
                        Image(systemName: "text.badge.minus")
                            .font(.title2)
                            .foregroundStyle(.quaternary)
                        Text("Response rendering paused")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text("Will appear when benchmark completes")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                    }
                    .padding(.vertical, Spacing.lg)
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            } else {
                // Use TextEditor for efficient rendering of long streaming text
                // (SwiftUI Text recalculates layout on every change, causing slowdown)
                // Observe the isolated ResponseTextStore — not viewModel.responseText —
                // so metric card @Published flushes don't trigger NSTextView re-evaluation.
                StreamingResponseView(
                    store: viewModel.responseTextStore,
                    placeholder: "Response will appear here..."
                )
            }
        }
    }

    // MARK: - Thinking Help Popover

    /// Explainer attached to the (i) next to the Thinking picker.
    /// Consolidates everything users need to know about the toggle
    /// — what each mode does, which backends honour it, and what to
    /// do when a model rejects the `think` field — in one spot,
    /// rather than discovering it only via the error message.
    private var thinkingHelpPopover: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(.purple)
                Text("Ollama Thinking Mode")
                    .font(.headline)
            }

            Text("Controls the `think` field sent on each Ollama generate request — Ollama's switch for showing or hiding a model's chain-of-thought.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Group {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto").fontWeight(.semibold)
                        Text("Omits the field entirely so the model uses its server-side default. Safest with older Ollama versions and non-reasoning models, which reject the field outright.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "wand.and.stars").foregroundStyle(.blue) }

                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("On").fontWeight(.semibold)
                        Text("Sends `think: true` to force chain-of-thought. Reasoning tokens are tracked separately so tok/s reflects output only, not thinking time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "checkmark.circle").foregroundStyle(.green) }

                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Off").fontWeight(.semibold)
                        Text("Sends `think: false` to suppress chain-of-thought even on models that reason by default. Output goes straight to the final answer.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "xmark.circle").foregroundStyle(.orange) }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Label("Backend support varies", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Only **Ollama** exposes a `think` parameter, so this control hides for OpenAI-compatible backends (LM Studio, MLX, vLLM, etc.). Those backends generally surface or hide reasoning via the model's own template or a server-side flag.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label("Got a model rejection error?", systemImage: "arrow.uturn.backward.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                Text("If a benchmark fails with a message that the model doesn't accept the `think` field, switch back to **Auto** (or **Off** for non-reasoning models). Anubis already shows a friendly error in that case — this picker is where you act on it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.md)
        .frame(width: 360)
    }

    // MARK: - Metrics Cards Section

    private var metricsCardsSection: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: Spacing.xs) {
            // Row 1: Performance
            CompactMetricsCard(
                title: "Tokens/sec",
                value: viewModel.formattedTokensPerSecond,
                icon: "bolt.fill",
                color: .chartTokens,
                subtitle: viewModel.peakTokensPerSecond > 0 ? "Peak: \(viewModel.formattedPeakTokensPerSecond)" : nil,
                help: viewModel.currentSession?.hasSuspiciousTiming == true
                    ? "⚠️ This backend did not stream tokens incrementally — generation duration came back implausibly short for the token count, so tok/s reflects burst-decode time rather than real generation time. Try a backend that streams (Ollama, LM Studio with streaming enabled)."
                    : "Average: total tokens ÷ generation time. Peak: highest instantaneous rate between sample intervals."
            )

            CompactMetricsCard(
                title: "GPU",
                value: String(format: "%.0f%%", viewModel.gpuUtilizationPercent),
                icon: "gpu",
                color: .chartGPU,
                available: viewModel.hasHardwareMetrics,
                help: "GPU utilization from IOReport."
            )

            CompactMetricsCard(
                title: "CPU",
                value: String(format: "%.0f%%", viewModel.cpuUtilizationPercent),
                icon: "cpu",
                color: .chartCPU,
                help: "CPU utilization across all cores."
            )

            CompactMetricsCard(
                title: "TTFT",
                value: viewModel.formattedTTFT,
                icon: "clock.arrow.circlepath",
                color: .chartTokens,
                subtitle: viewModel.prefillTokensPerSecond.map { "Prefill: \(Formatters.tokensPerSecond($0))" },
                help: "Time to first token (includes any reasoning/thinking phase for reasoning models). Subtitle shows prefill speed: input tokens ÷ TTFT."
            )

            // Row 2: Power & System
            CompactMetricsCard(
                title: "Avg GPU Power",
                value: viewModel.avgGPUPowerFormatted,
                icon: "bolt.horizontal.fill",
                color: .chartGPUPower,
                available: viewModel.hasPowerMetrics,
                subtitle: viewModel.peakGpuPower > 0 ? "Peak: \(viewModel.peakGPUPowerFormatted)" : nil,
                help: "Average GPU power during benchmark."
            )

            CompactMetricsCard(
                title: "Avg System Power",
                value: viewModel.avgSystemPowerFormatted,
                icon: "powerplug.fill",
                color: .chartSystemPower,
                available: viewModel.hasPowerMetrics,
                subtitle: viewModel.peakSystemPower > 0 ? "Peak: \(viewModel.peakSystemPowerFormatted)" : nil,
                help: "Average SoC power (GPU + CPU + ANE + DRAM)."
            )

            CompactMetricsCard(
                title: "J/Token",
                value: viewModel.currentWattsPerTokenFormatted,
                icon: "leaf.fill",
                color: .chartEfficiency,
                available: viewModel.hasPowerMetrics,
                help: "Power efficiency: avg system watts ÷ tokens/sec."
            )

            CompactMetricsCard(
                title: "Tot. Memory",
                value: viewModel.formattedBackendMemory,
                icon: "memorychip",
                color: .chartMemory,
                help: "Total resident memory of the backend process tree (server + model + children)."
            )
        }
    }

    private var thermalColor: Color {
        switch viewModel.currentMetrics?.thermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        case .none: return .gray
        }
    }

    // MARK: - Charts Section

    private var chartsSection: some View {
        VStack(spacing: Spacing.md) {
            if viewModel.showLiveCharts {
                // Chart views observe chartStore independently from viewModel,
                // so chart updates won't trigger text streaming re-renders and vice versa.
                LiveChartsView(
                    chartStore: viewModel.chartStore,
                    isRunning: viewModel.isRunning,
                    hasHardwareMetrics: viewModel.hasHardwareMetrics,
                    hasPowerMetrics: viewModel.hasPowerMetrics,
                    currentMemoryBytes: viewModel.effectiveBackendMemoryBytes,
                    totalMemoryBytes: viewModel.currentMetrics?.memoryTotalBytes ?? 1,
                    perCoreSnapshot: viewModel.latestPerCoreSnapshot,
                    onExpandCores: { viewModel.openCoreDetailWindow() },
                    gpuUtilization: viewModel.latestGPUUtilization,
                    onExpandGPU: { viewModel.openGPUDetailWindow() },
                    averageTps: viewModel.effectiveAverageTps,
                    elapsedTime: viewModel.elapsedTime
                )
            } else {
                // Collapsed state - show placeholder
                HStack {
                    Spacer()
                    VStack(spacing: Spacing.xs) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.title2)
                            .foregroundStyle(.quaternary)
                        Text("Charts paused")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text("Toggle on to view collected data")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                    }
                    .padding(.vertical, Spacing.lg)
                    Spacer()
                }
                .background {
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .fill(Color.emptyStateBackground)
                        .overlay {
                            RoundedRectangle(cornerRadius: CornerRadius.md)
                                .strokeBorder(Color.cardBorder, lineWidth: 1)
                        }
                }
            }
        }
    }

    // MARK: - Run Group UI (Phase 1.2)

    /// In-progress banner: "Run X of N" while a group is iterating.
    @ViewBuilder
    private var groupProgressBanner: some View {
        if let group = viewModel.currentRunGroup,
           group.status == .running,
           viewModel.currentRepetitionIndex > 0 {
            HStack(spacing: Spacing.sm) {
                // Static icon — the .symbolEffect(.pulse) animation
                // forced a continuous Core Animation transaction every
                // frame on the parent view tree, which competed with
                // text-flush during group streaming. The per-rep dots
                // (right side) already convey progress.
                Image(systemName: "repeat")
                    .foregroundStyle(Color.chartTokens)
                Text("Run \(viewModel.currentRepetitionIndex) of \(group.repetitions)")
                    .font(.subheadline.weight(.semibold))
                Text(group.seedStrategy == .random ? "· random seed per rep" : "· fixed seed \(group.fixedSeed ?? 0)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // Tiny progress dots — one per rep, filled = completed,
                // hollow = pending, current = pulsing.
                HStack(spacing: 4) {
                    ForEach(0..<group.repetitions, id: \.self) { idx in
                        Circle()
                            .fill(idx < group.completedRepetitions
                                  ? Color.chartTokens
                                  : (idx + 1 == viewModel.currentRepetitionIndex
                                     ? Color.chartTokens.opacity(0.5)
                                     : Color.cardBorder))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .padding(Spacing.sm)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.cardBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.chartTokens.opacity(0.3), lineWidth: 1)
                    }
            }
        }
    }

    /// Post-completion summary card: mean ± 95% CI for each metric.
    /// Shown only when the current group has finished (any status
    /// except .running) — supersedes the per-session detail view as
    /// the headline result.
    @ViewBuilder
    private var groupSummaryCard: some View {
        if let group = viewModel.currentRunGroup,
           group.status != .running,
           (group.sampleCount ?? 0) > 0 {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Image(systemName: group.status == .completed
                          ? "checkmark.seal.fill"
                          : (group.status == .cancelled ? "xmark.octagon" : "exclamationmark.triangle"))
                        .foregroundStyle(group.status == .completed ? Color.chartTokens : .orange)
                    Text(group.status == .completed
                         ? "Group complete · n=\(group.sampleCount ?? 0)"
                         : "Group \(group.status.rawValue) · \(group.completedRepetitions)/\(group.repetitions) runs")
                        .font(.headline)
                    Spacer()
                    // View-mode toggle controls whether the lower
                    // dashboard cards/charts show group means or the
                    // last rep's numbers. Renders only when there's
                    // more than one completed rep to average.
                    if (group.sampleCount ?? 0) > 1 {
                        Picker("", selection: $viewModel.groupViewMode) {
                            Text("Group mean").tag(BenchmarkViewModel.GroupViewMode.fullGroup)
                            Text("Last rep").tag(BenchmarkViewModel.GroupViewMode.lastRep)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                        .help("Switch the dashboard between the group's mean across all reps and just the most recent rep's values. The summary card above always shows the group mean.")
                    }
                    Text(group.seedStrategy == .random ? "random seeds" : "fixed seed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), alignment: .leading, spacing: Spacing.sm) {
                    groupMetricRow(
                        label: "Output tok/s",
                        mean: group.meanTokensPerSecond,
                        ciLow: group.ciLowTokensPerSecond,
                        ciHigh: group.ciHighTokensPerSecond,
                        format: { String(format: "%.1f", $0) }
                    )
                    groupMetricRow(
                        label: "TTFT",
                        mean: group.meanTimeToFirstToken,
                        ciLow: group.ciLowTimeToFirstToken,
                        ciHigh: group.ciHighTimeToFirstToken,
                        format: { String(format: "%.0f ms", $0 * 1000) }
                    )
                    groupMetricRow(
                        label: "J/tok",
                        mean: group.meanWattsPerToken,
                        ciLow: group.ciLowWattsPerToken,
                        ciHigh: group.ciHighWattsPerToken,
                        format: { String(format: "%.3f", $0) }
                    )
                    groupMetricRow(
                        label: "Avg system W",
                        mean: group.meanSystemPowerWatts,
                        ciLow: group.ciLowSystemPowerWatts,
                        ciHigh: group.ciHighSystemPowerWatts,
                        format: { String(format: "%.2f W", $0) }
                    )
                    groupMetricRow(
                        label: "Peak memory",
                        mean: group.meanPeakMemoryBytes,
                        ciLow: group.ciLowPeakMemoryBytes,
                        ciHigh: group.ciHighPeakMemoryBytes,
                        format: { Formatters.bytes(Int64($0)) }
                    )
                }

                Text("95% bootstrap CI · 1000 resamples. Per-rep results visible in Session History.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .padding(Spacing.md)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.cardBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(group.status == .completed ? Color.chartTokens.opacity(0.4) : Color.cardBorder, lineWidth: 1)
                    }
            }
        }
    }

    /// Compact "label  mean (CI low – high)" row for the summary card.
    private func groupMetricRow(
        label: String,
        mean: Double?,
        ciLow: Double?,
        ciHigh: Double?,
        format: (Double) -> String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            if let m = mean {
                Text(format(m))
                    .font(.mono(13, weight: .semibold))
                if let lo = ciLow, let hi = ciHigh {
                    Text("(\(format(lo))–\(format(hi)))")
                        .font(.mono(10))
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("—")
                    .font(.mono(13))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    // MARK: - Detailed Stats Section

    private var detailedStatsSection: some View {
        DisclosureGroup(isExpanded: $showSessionDetails) {
            detailedStatsGrid
                .padding(.top, Spacing.xs)
        } label: {
            Text("Session Details")
                .font(.headline)
                .contentShape(Rectangle())
        }
    }

    /// Effective Session Details source: default to oMLX's own metrics whenever
    /// the run has them; respect the user's explicit choice once they make one.
    private var showServerReportedDetails: Bool {
        detailsSourceOverride ?? hasServerReportedMetrics
    }

    private var detailedStatsGrid: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // The user selected the built-in oMLX backend but the server hasn't
            // identified as oMLX — warn that the metrics aren't server-verified.
            if viewModel.isBuiltInOMLXBackend && !viewModel.isVerifiedOMLX {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("This server isn't identifying as oMLX — metrics are Anubis-measured, not server-reported.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            // oMLX reports its own metrics — let the user swap the grid to the
            // server's verbatim figures, marked as server-verified.
            if hasServerReportedMetrics {
                HStack(spacing: 6) {
                    if showServerReportedDetails {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text("Reported directly by the oMLX server")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { showServerReportedDetails },
                        set: { detailsSourceOverride = $0 }
                    )) {
                        Text("Anubis").tag(false)
                        Text("oMLX").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            if showServerReportedDetails, let metrics = currentServerMetrics {
                serverReportedStatsGrid(metrics)
            } else {
                anubisStatsGrid
            }

            // Chip info + backend summary line
            detailedStatsSummaryLine
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
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

    /// The current session's oMLX-reported `usage` block, parsed. nil unless
    /// the run was against a server that reports its own metrics (oMLX).
    private var currentServerMetrics: [String: Any]? {
        guard let json = viewModel.currentSession?.serverMetricsJSON,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private var hasServerReportedMetrics: Bool { currentServerMetrics != nil }

    /// Session Details grid built straight from oMLX's reported usage block —
    /// every value is the server's own number, not Anubis-derived.
    private func serverReportedStatsGrid(_ m: [String: Any]) -> some View {
        func dbl(_ key: String) -> Double? { (m[key] as? NSNumber)?.doubleValue }
        func intVal(_ key: String) -> Int? { (m[key] as? NSNumber)?.intValue }
        let cached = ((m["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? NSNumber)?.intValue

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.sm), count: 6), spacing: Spacing.xs) {
            serverCell("Prefill Speed", dbl("prompt_tokens_per_second").map { String(format: "%.2f tok/s", $0) })
            serverCell("Generation Speed", dbl("generation_tokens_per_second").map { String(format: "%.2f tok/s", $0) })
            serverCell("Time to First Token", dbl("time_to_first_token").map { String(format: "%.2fs", $0) })
            serverCell("Total Time", dbl("total_time").map { String(format: "%.2fs", $0) })
            serverCell("Prompt Eval", dbl("prompt_eval_duration").map { String(format: "%.2fs", $0) })
            serverCell("Generation", dbl("generation_duration").map { String(format: "%.2fs", $0) })
            serverCell("Model Load", dbl("model_load_duration").map { String(format: "%.2fs", $0) })
            serverCell("Cached Tokens", cached.map { "\($0)" })
            serverCell("Prompt Tokens", intVal("prompt_tokens").map { "\($0)" })
            serverCell("Completion Tokens", intVal("completion_tokens").map { "\($0)" })
            serverCell("Total Tokens", intVal("total_tokens").map { "\($0)" })
        }
    }

    private func serverCell(_ title: String, _ value: String?) -> some View {
        DetailStatCell(title: title, value: value ?? "—", icon: "checkmark.seal.fill", color: .green)
    }

    private var anubisStatsGrid: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.sm), count: 6), spacing: Spacing.xs) {
                // 6-wide flow — two compact rows instead of three.
                DetailStatCell(
                    title: "Avg Token Latency",
                    value: viewModel.currentSession?.averageTokenLatencyMs.map { Formatters.milliseconds($0) } ?? "—",
                    icon: "clock.fill",
                    color: .chartTokens
                )

                DetailStatCell(
                    title: "Model Load Time",
                    value: viewModel.currentSession?.loadDuration.map { Formatters.duration($0) } ?? "—",
                    icon: "arrow.down.circle.fill",
                    color: .anubisMuted
                )

                DetailStatCell(
                    title: "Context Length",
                    value: viewModel.currentSession?.contextLength.map { "\($0) tokens" } ?? "—",
                    icon: "text.alignleft",
                    color: .chartCPU
                )

                DetailStatCell(
                    title: "GPU Frequency",
                    value: viewModel.currentGPUFrequencyFormatted,
                    icon: "gauge.with.dots.needle.67percent",
                    color: .chartFrequency
                )

                // Row 2: Peak Memory / Prompt Tokens / Completion Tokens / Eval Duration
                DetailStatCell(
                    title: "Peak Memory",
                    value: viewModel.formattedPeakMemory,
                    icon: "arrow.up.right",
                    color: .chartMemory
                )

                DetailStatCell(
                    title: "Prompt Tokens",
                    value: viewModel.currentSession?.promptTokens.map { "\($0)" } ?? "—",
                    icon: "arrow.right.circle.fill",
                    color: .chartCPU
                )

                DetailStatCell(
                    title: "Completion Tokens",
                    value: viewModel.currentSession?.completionTokens.map { "\($0)" }
                        ?? (viewModel.tokensGenerated > 0 ? "\(viewModel.tokensGenerated)" : "—"),
                    icon: "number",
                    color: .chartTokens
                )

                DetailStatCell(
                    title: "Eval Duration",
                    value: viewModel.currentSession?.evalDuration.map { Formatters.duration($0) } ?? "—",
                    icon: "timer",
                    color: .anubisMuted
                )

                // Row 3: Thermal / Peak GPU Power / Avg J/Token / Connection
                DetailStatCell(
                    title: "Thermal",
                    value: viewModel.currentMetrics?.thermalState.description ?? "—",
                    icon: "thermometer.medium",
                    color: .anubisWarning
                )

                DetailStatCell(
                    title: "Peak GPU Power",
                    value: viewModel.currentSession?.peakGpuPowerWatts.map { Formatters.watts($0) } ?? "—",
                    icon: "bolt.fill",
                    color: .chartGPUPower
                )

                DetailStatCell(
                    title: "Avg J/Token",
                    value: viewModel.currentSession?.avgWattsPerToken.map { String(format: "%.2f J/tok", $0) } ?? "—",
                    icon: "leaf.fill",
                    color: .chartEfficiency
                )

                DetailStatCell(
                    title: "Connection",
                    value: viewModel.connectionName,
                    icon: "network",
                    color: .anubisMuted
                )
            }
        }
    }

    /// Chip info + backend summary line shown beneath either stats grid.
    private var detailedStatsSummaryLine: some View {
        HStack(spacing: Spacing.sm) {
            Text(viewModel.selectedModel?.name ?? viewModel.currentSession?.modelName ?? "—")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)

            if let quant = viewModel.selectedModel?.quantization ?? viewModel.currentSession?.modelQuantization {
                Text("•").font(.caption2).foregroundStyle(.quaternary)
                Text(quant)
                    .font(.caption2.monospaced().weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if let format = viewModel.selectedModel?.modelFormat?.rawValue ?? viewModel.currentSession?.modelFormat {
                Text("•").font(.caption2).foregroundStyle(.quaternary)
                Text(format)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(format == "MLX" ? Color.purple : Color.green)
            }

            Text("•")
                .font(.caption2)
                .foregroundStyle(.quaternary)

            let chip = ChipInfo.current
            Text(chip.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("•")
                .font(.caption2)
                .foregroundStyle(.quaternary)

            Text("Process: \(viewModel.currentBackendProcessName ?? "None")")
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Menu renders as broken image in ImageRenderer, so keep it
            // minimal — the static text above carries the info for exports.
            ProcessPickerMenu(viewModel: viewModel)
                .accessibilityIdentifier("processPickerMenu")

            Spacer()

            Text(viewModel.isRunning ? "Running" : (viewModel.currentSession?.status.rawValue.capitalized ?? "—"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, Spacing.xxs)
    }
}

// MARK: - Inference Stats Button

private struct InferenceStatsButton: View {
    let session: BenchmarkSession
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .popover(isPresented: $showing, arrowEdge: .top) {
            popoverContent
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Inference Stats")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            if let v = session.tokensPerSecond {
                statRow("response_token/s", formatDecimal(v))
            }
            if let promptTokens = session.promptTokens,
               let promptEval = session.promptEvalDuration, promptEval > 0 {
                statRow("prompt_token/s", formatDecimal(Double(promptTokens) / promptEval))
            }
            if let v = session.totalDuration {
                statRow("total_duration", formatDuration(v))
            }
            if let v = session.loadDuration {
                statRow("load_duration", formatDuration(v))
            }
            if let v = session.promptTokens {
                statRow("prompt_eval_count", "\(v)")
            }
            if let v = session.completionTokens {
                statRow("eval_count", "\(v)")
            }
            if let v = session.promptEvalDuration {
                statRow("prompt_eval_duration", formatDuration(v))
            }
            if let v = session.evalDuration {
                statRow("eval_duration", formatDuration(v))
            }
            if let v = session.totalTokens {
                statRow("total_tokens", "\(v)")
            }
            if let rt = session.reasoningTokens, rt > 0 {
                statRow("reasoning_tokens", "\(rt)")
                if let rd = session.reasoningDuration, rd > 0 {
                    statRow("reasoning_duration", formatDuration(rd))
                    statRow("reasoning_token/s", formatDecimal(Double(rt) / rd))
                }
            }

            // v12 run conditions. What was asked for and what the machine was
            // doing while it ran — without these two a result cannot be
            // compared against another one.
            if session.maxTokensRequested != nil || session.finishReason != nil
                || session.thermalNonNominalFraction != nil {
                Divider()
                    .padding(.vertical, 3)
                Text("Run conditions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)

                if let v = session.maxTokensRequested {
                    statRow("max_tokens", "\(v)")
                }
                if let reason = session.finishReason {
                    statRow("finish_reason", reason)
                }
                if let t = session.temperature {
                    statRow("temperature", formatDecimal(t))
                }
                if let p = session.topP {
                    statRow("top_p", formatDecimal(p))
                }
                if let s = session.seed {
                    statRow("seed", "\(s)")
                }
                if let frac = session.thermalNonNominalFraction {
                    statRow("thermal_non_nominal", "\(Int((frac * 100).rounded()))%")
                }
            }

            if session.ranUnderThermalPressure {
                thermalWarning
            }

            // oMLX reports its own metrics; show them verbatim, exactly as the
            // server sent them (including fields we don't otherwise surface).
            let serverRows = omlxReportedRows
            if !serverRows.isEmpty {
                Divider()
                    .padding(.vertical, 3)
                Text("Reported by oMLX")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                ForEach(serverRows.indices, id: \.self) { i in
                    statRow(serverRows[i].label, serverRows[i].value)
                }
            }
        }
        .padding(Spacing.sm)
        .frame(width: 260)
    }

    /// Parse the backend's raw `usage` JSON (oMLX) into flat label/value rows,
    /// preserving the server's own numbers without rounding or renaming.
    private var omlxReportedRows: [(label: String, value: String)] {
        guard let json = session.serverMetricsJSON,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        var rows: [(label: String, value: String)] = []
        for key in obj.keys.sorted() {
            guard let value = obj[key] else { continue }
            if let nested = value as? [String: Any] {
                for subKey in nested.keys.sorted() {
                    if let subValue = nested[subKey] {
                        rows.append((label: "\(key).\(subKey)", value: formatJSONValue(subValue)))
                    }
                }
            } else {
                rows.append((label: key, value: formatJSONValue(value)))
            }
        }
        return rows
    }

    /// Render a JSON scalar the way the server stated it: integers as integers,
    /// fractionals with trailing zeros trimmed (so 0.8 stays "0.8", not "0.80").
    private func formatJSONValue(_ value: Any) -> String {
        if let n = value as? NSNumber {
            // Bools decode to NSNumber; surface them as true/false.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            let d = n.doubleValue
            if d == d.rounded() && abs(d) < 1e15 {
                return String(Int(d))
            }
            return String(format: "%g", d)
        }
        return String(describing: value)
    }

    /// Shown when any part of the run executed under thermal pressure.
    /// Sustained decode can cut throughput several-fold before the OS raises
    /// the flag, so such a run is not comparable to one recorded at nominal.
    private var thermalWarning: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "thermometer.high")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text("Ran under thermal pressure — not comparable to a run at nominal.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.mono(12, weight: .medium))
        }
    }

    private func formatDecimal(_ v: Double) -> String {
        String(format: "%.2f", v)
    }

    private func formatDuration(_ seconds: Double) -> String {
        String(format: "%.2fs", seconds)
    }
}

// MARK: - Detail Stat Cell

struct DetailStatCell: View {
    let title: String
    let value: String
    var icon: String? = nil
    var color: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if let icon, let color {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                        .foregroundStyle(color)
                }
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Text(value)
                .font(.mono(13, weight: .medium))
                .foregroundStyle(value == "—" ? .tertiary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Thermal State Description

extension ThermalState {
    var description: String {
        switch self {
        case .nominal: return "Normal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }
}

// MARK: - Streaming Response Wrapper

/// Wrapper that observes only the ResponseTextStore, isolating the NSTextView
/// from BenchmarkViewModel's @Published cascade.
private struct StreamingResponseView: View {
    @ObservedObject var store: ResponseTextStore
    let placeholder: String

    var body: some View {
        StreamingTextView(text: store.text, placeholder: placeholder)
    }
}

// MARK: - Streaming Text View

/// Efficient text view for streaming content using NSTextView with incremental append.
///
/// Instead of replacing the full string on every update (O(n) comparison + O(n) relayout),
/// this tracks how much text has been rendered and only appends the new delta via
/// NSTextStorage — making each update O(delta) regardless of total response length.
struct StreamingTextView: NSViewRepresentable {
    let text: String
    let placeholder: String

    /// Streaming-optimised system font with OpenType ligature features
    /// pre-disabled at the CTFont level. Setting `.ligature: 0` only as
    /// an NSAttributedString attribute is not enough — CoreText still
    /// calls `CopyOfFontWithLigatureSetting` on every layout pass,
    /// which iterates the font's feature array and burns the main
    /// thread (see hang sample 2026-05-22). Baking the setting into
    /// the font descriptor itself bypasses that hot path entirely.
    private static let streamingFont: NSFont = {
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        // CTFontFeatureType 1 == kLigaturesType; selector 0 = required-off,
        // 2 = common-off, 4 = rare-off, 8 = contextual-off, 22 = historical-off.
        // Disable every common/optional ligature variant so the layout
        // manager never asks CoreText to "compute the non-default settings".
        let featureSettings: [[CFString: Int]] = [
            [kCTFontFeatureTypeIdentifierKey: 1, kCTFontFeatureSelectorIdentifierKey: 2],  // common
            [kCTFontFeatureTypeIdentifierKey: 1, kCTFontFeatureSelectorIdentifierKey: 4],  // rare
            [kCTFontFeatureTypeIdentifierKey: 1, kCTFontFeatureSelectorIdentifierKey: 8],  // contextual
            [kCTFontFeatureTypeIdentifierKey: 1, kCTFontFeatureSelectorIdentifierKey: 22], // historical
        ]
        let descriptor = base.fontDescriptor.addingAttributes([
            NSFontDescriptor.AttributeName(kCTFontFeatureSettingsAttribute as String): featureSettings
        ])
        return NSFont(descriptor: descriptor, size: NSFont.systemFontSize) ?? base
    }()

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 (NSLayoutManager + NSATSTypesetter). TK2 was
        // briefly tried thinking we needed it to bypass the
        // CopyOfFontWithLigatureSetting hot path in NSATSTypesetter
        // that caused a hang at ~25 reps. The actual load-bearing
        // fix was the font-level ligature disable below (the
        // Self.streamingFont property) — that bakes ligature-off
        // into the font descriptor itself so CoreText never iterates
        // the feature array, regardless of TextKit version. TK2's
        // viewport-based lazy layout fights with the constant text
        // appends of streaming inference, dropping/re-laying-out
        // fragments on scroll. TK1 lays out greedily and scrolls
        // natively; at our response sizes the perf cost is nothing.
        let textView = NSTextView(usingTextLayoutManager: false)

        // Standard NSTextView sizing for a vertically-scrolling
        // document. minSize.height is kept in sync with the scroll
        // view's content height inside updateNSView so the textView
        // frame doesn't collapse below the visible region.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,                                  // 0 + widthTracksTextView ⇒ follow textView width
            height: CGFloat.greatestFiniteMagnitude    // no vertical clip
        )

        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.font = Self.streamingFont
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 12, height: 12)

        // Read-only display: all the automatic substitutions /
        // spell-check / data-detection scans cost cycles on a
        // multi-paragraph response and serve no purpose for LLM
        // output. Disabling them is just hygiene.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false

        textView.typingAttributes = [
            .font: Self.streamingFont,
            .foregroundColor: NSColor.labelColor,
            .kern: 0,
            .ligature: 0,
        ]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        // Show placeholder initially
        if text.isEmpty {
            textView.string = placeholder
            textView.textColor = .secondaryLabelColor
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        let newNSLength = (text as NSString).length

        // Keep the textView's minSize.height in sync with the scroll
        // view's content area so the textView frame doesn't collapse
        // below the visible region. We can't do this in makeNSView
        // because the hosted view isn't laid out yet at that point.
        let visibleHeight = scrollView.contentSize.height
        if visibleHeight > 0, abs(textView.minSize.height - visibleHeight) > 0.5 {
            textView.minSize = NSSize(width: 0, height: visibleHeight)
        }

        if text.isEmpty {
            // Show placeholder (or already showing it)
            if !coordinator.isShowingPlaceholder {
                textView.string = placeholder
                textView.textColor = .secondaryLabelColor
                coordinator.isShowingPlaceholder = true
                coordinator.renderedUTF16Length = 0
            }
            return
        }

        // Text was reset (new benchmark started) — full replacement
        if newNSLength < coordinator.renderedUTF16Length || coordinator.isShowingPlaceholder {
            coordinator.isShowingPlaceholder = false
            textView.textColor = .labelColor
            textView.string = text
            coordinator.renderedUTF16Length = newNSLength
            textView.scrollToEndOfDocument(nil)
            return
        }

        // No change — skip entirely (O(1) integer check)
        if newNSLength == coordinator.renderedUTF16Length {
            return
        }

        // Incremental append — only the new delta via NSTextStorage
        let wasAtBottom = isScrolledToBottom(scrollView)
        let delta = (text as NSString).substring(from: coordinator.renderedUTF16Length)

        if let storage = textView.textStorage {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Self.streamingFont,
                .foregroundColor: NSColor.labelColor,
                .kern: 0,
                .ligature: 0,
            ]
            storage.beginEditing()
            storage.append(NSAttributedString(string: delta, attributes: attrs))
            storage.endEditing()
        }

        coordinator.renderedUTF16Length = newNSLength

        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    class Coordinator {
        /// Tracks how many UTF-16 code units have been rendered in the NSTextView.
        /// NSString.length is O(1), so this comparison is always cheap.
        var renderedUTF16Length: Int = 0
        var isShowingPlaceholder: Bool = true
    }

    private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
        guard let textView = scrollView.documentView as? NSTextView else { return true }
        let visibleRect = scrollView.contentView.bounds
        let contentHeight = textView.bounds.height
        return visibleRect.maxY >= contentHeight - 50
    }
}

// MARK: - Model Memory Card

/// Card showing model memory usage (unified memory on Apple Silicon)
struct ModelMemoryCard: View {
    let total: Int64
    let gpu: Int64
    let cpu: Int64
    var isOllamaBackend: Bool = true

    private let helpText = "Model allocation reported by Ollama's /api/ps endpoint. On Apple Silicon, GPU and CPU share unified memory. Total Memory (above) shows the full resident footprint."

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Image(systemName: "memorychip")
                    .font(.caption)
                    .foregroundStyle(Color.chartMemory)
                Text("Model Memory")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                HelpButton(text: helpText)
                if !isOllamaBackend {
                    Text("N/A")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if !isOllamaBackend {
                // Non-Ollama backends don't provide model memory info
                Text("—")
                    .font(.anubisMetricSmall)
                    .foregroundStyle(.tertiary)
            } else if total > 0 {
                // Total size - this is what matters on Apple Silicon (unified memory)
                Text(Formatters.bytes(total))
                    .font(.anubisMetricSmall)
            } else {
                Text("—")
                    .font(.anubisMetricSmall)
                    .foregroundStyle(.tertiary)
            }

            // Always show subtitle for consistent height
            Text(subtitleText)
                .font(.caption2)
                .foregroundStyle(subtitleColor)
        }
        .metricCardStyle()
    }

    private var subtitleText: String {
        if !isOllamaBackend {
            return "Ollama only"
        } else if total > 0 {
            return "Unified Memory"
        } else {
            return "Waiting for model..."
        }
    }

    private var subtitleColor: Color {
        if !isOllamaBackend || total == 0 {
            return .secondary.opacity(0.6)
        }
        return .secondary
    }
}

// MARK: - Expanded Metrics View

/// Screenshot-friendly benchmark results dashboard.
/// Designed for content creators to capture and share in videos/posts.
struct ExpandedMetricsView: View {
    @ObservedObject var viewModel: BenchmarkViewModel
    @State private var showLeaderboardUpload = false

    private var chip: ChipInfo { ChipInfo.current }
    private let topColumns = [GridItem(.flexible()), GridItem(.flexible())]
    private let threeColumns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    private var chartData: BenchmarkChartData { viewModel.chartStore.chartData }
    private var tpsIsComplete: Bool { !viewModel.isRunning }
    private var tpsDisplayValue: Double? { tpsIsComplete ? viewModel.effectiveAverageTps : nil }
    private var tpsValueNote: String { tpsIsComplete ? "avg" : "live" }

    var body: some View {
        GeometryReader { geo in
            let chartHeight = expandedChartHeight(availableHeight: geo.size.height)
            // Total card height = chart area + title/header (~30px) + card padding (~24px)
            let cardHeight = chartHeight + 54
            ScrollView {
                LazyVGrid(columns: threeColumns, spacing: Spacing.md) {
                    // Row 1: Hero | Metrics | Tok/s chart
                    heroCard.frame(height: cardHeight)
                    metricsCard.frame(height: cardHeight)
                    TimelineChart(
                        title: "Tokens/Sec",
                        data: chartData.tokensPerSecond,
                        color: .chartTokens,
                        unit: "tok/s",
                        valueNote: tpsValueNote,
                        displayValue: tpsDisplayValue,
                        chartHeight: chartHeight
                    )

                    // Row 2: CPU Util | Memory | GPU Util
                    TimelineChart(
                        title: "CPU Utilization",
                        data: chartData.cpuUtilization,
                        color: .chartCPU,
                        unit: "%",
                        maxValue: 100,
                        chartHeight: chartHeight
                    )
                    MemoryTimelineChart(
                        title: "Tot. Memory",
                        data: chartData.memoryUtilization,
                        currentBytes: viewModel.effectiveBackendMemoryBytes,
                        totalBytes: viewModel.currentMetrics?.memoryTotalBytes ?? 1,
                        color: .chartMemory,
                        chartHeight: chartHeight
                    )
                    if viewModel.hasHardwareMetrics {
                        TimelineChart(
                            title: "GPU Utilization",
                            data: chartData.gpuUtilization,
                            color: .chartGPU,
                            unit: "%",
                            maxValue: 100,
                            chartHeight: chartHeight
                        )
                    }

                    // Power rows — gate on capability, not sample presence,
                    // so cards show their empty state before a run too.
                    if viewModel.hasPowerMetrics {
                        // Row 3: CPU Cores | GPU Cores | System Power
                        CoreUtilizationGrid(snapshot: viewModel.latestPerCoreSnapshot) {
                            viewModel.openCoreDetailWindow()
                        }
                        GPUCoreGrid(gpuUtilization: viewModel.latestGPUUtilization) {
                            viewModel.openGPUDetailWindow()
                        }
                        TimelineChart(
                            title: "System Power",
                            data: chartData.systemPower,
                            color: .chartSystemPower,
                            unit: "W",
                            chartHeight: chartHeight
                        )

                        // Row 4: GPU Power | Energy per Token | GPU Frequency
                        TimelineChart(
                            title: "GPU Power",
                            data: chartData.gpuPower,
                            color: .chartGPUPower,
                            unit: "W",
                            chartHeight: chartHeight
                        )
                        TimelineChart(
                            title: "Energy per Token",
                            data: chartData.wattsPerToken,
                            color: .chartEfficiency,
                            unit: "J/tok",
                            chartHeight: chartHeight
                        )
                        TimelineChart(
                            title: "GPU Frequency",
                            data: chartData.gpuFrequency,
                            color: .chartFrequency,
                            unit: "MHz",
                            chartHeight: chartHeight
                        )

                        // Row 5: CPU Power
                        TimelineChart(
                            title: "CPU Power",
                            data: chartData.cpuPower,
                            color: .chartCPUPower,
                            unit: "W",
                            chartHeight: chartHeight
                        )
                        TimelineChart(
                            title: "Time",
                            data: chartData.cpuPower,
                            color: .chartCPUPower,
                            unit: "W",
                            chartHeight: chartHeight
                        )
                    } else {
                        // No power — just show core grids
                        CoreUtilizationGrid(snapshot: viewModel.latestPerCoreSnapshot) {
                            viewModel.openCoreDetailWindow()
                        }
                        GPUCoreGrid(gpuUtilization: viewModel.latestGPUUtilization) {
                            viewModel.openGPUDetailWindow()
                        }
                    }
                }
                .padding(Spacing.lg)
            }
        }
        .background(Color.dashboardBackground.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            HStack(spacing: Spacing.sm) {
                Button {
                    showLeaderboardUpload = true
                } label: {
                    Image(systemName: "globe.badge.chevron.backward")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.currentSession?.status != .completed)
                .help("Upload to community leaderboard")

                exportMenu
            }
            .padding(Spacing.lg)
        }
        .sheet(isPresented: $showLeaderboardUpload) {
            if let session = viewModel.currentSession {
                LeaderboardUploadView(
                    session: session,
                    group: viewModel.currentRunGroup,
                    // While the group is mid-run, currentRepetitionIndex
                    // is the 1-based active rep. After completion it's
                    // reset to 0, in which case currentSession is the
                    // most recent (last) rep — use completedRepetitions
                    // for that index.
                    repetitionIndex: viewModel.currentRepetitionIndex > 0
                        ? viewModel.currentRepetitionIndex
                        : viewModel.currentRunGroup?.completedRepetitions,
                    onSubmitted: { viewModel.markCurrentSessionLeaderboardSubmitted() }
                )
            }
        }
    }

    // MARK: - Export

    private var exportMenu: some View {
        Menu {
            Button {
                copyToClipboard()
            } label: {
                Label("Copy to Clipboard", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)

            Button {
                saveAsPNG()
            } label: {
                Label("Save as PNG…", systemImage: "square.and.arrow.down")
            }

            Button {
                shareImage()
            } label: {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Export benchmark results")
    }

    /// The content rendered for export — 3-column layout matching the expanded view with fixed chart heights.
    private var exportableContent: some View {
        let exportHeight: CGFloat = 150
        return LazyVGrid(columns: threeColumns, spacing: Spacing.md) {
            heroCard
            metricsCard
            TimelineChart(
                title: "Tok/Second",
                data: chartData.tokensPerSecond,
                color: .chartTokens,
                unit: "tok/s",
                valueNote: tpsValueNote,
                displayValue: tpsDisplayValue,
                chartHeight: exportHeight
            )

            TimelineChart(
                title: "CPU Utilization",
                data: chartData.cpuUtilization,
                color: .chartCPU,
                unit: "%",
                maxValue: 100,
                chartHeight: exportHeight
            )
            MemoryTimelineChart(
                title: "Tot. Memory",
                data: chartData.memoryUtilization,
                currentBytes: viewModel.effectiveBackendMemoryBytes,
                totalBytes: viewModel.currentMetrics?.memoryTotalBytes ?? 1,
                color: .chartMemory,
                chartHeight: exportHeight
            )
            if viewModel.hasHardwareMetrics {
                TimelineChart(
                    title: "GPU Utilization",
                    data: chartData.gpuUtilization,
                    color: .chartGPU,
                    unit: "%",
                    maxValue: 100,
                    chartHeight: exportHeight
                )
            }

            if viewModel.hasPowerMetrics && chartData.hasPowerData {
                if !viewModel.latestPerCoreSnapshot.isEmpty {
                    CoreUtilizationGrid(snapshot: viewModel.latestPerCoreSnapshot) {}
                }
                GPUCoreGrid(gpuUtilization: viewModel.latestGPUUtilization) {}
                TimelineChart(
                    title: "System Power",
                    data: chartData.systemPower,
                    color: .chartSystemPower,
                    unit: "W",
                    chartHeight: exportHeight
                )

                TimelineChart(
                    title: "GPU Power",
                    data: chartData.gpuPower,
                    color: .chartGPUPower,
                    unit: "W",
                    chartHeight: exportHeight
                )
                TimelineChart(
                    title: "Energy per Token",
                    data: chartData.wattsPerToken,
                    color: .chartEfficiency,
                    unit: "J/tok",
                    chartHeight: exportHeight
                )
                TimelineChart(
                    title: "GPU Frequency",
                    data: chartData.gpuFrequency,
                    color: .chartFrequency,
                    unit: "MHz",
                    chartHeight: exportHeight
                )

                TimelineChart(
                    title: "CPU Power",
                    data: chartData.cpuPower,
                    color: .chartCPUPower,
                    unit: "W",
                    chartHeight: exportHeight
                )
            } else {
                if !viewModel.latestPerCoreSnapshot.isEmpty {
                    CoreUtilizationGrid(snapshot: viewModel.latestPerCoreSnapshot) {}
                }
                GPUCoreGrid(gpuUtilization: viewModel.latestGPUUtilization) {}
            }
        }
        .padding(Spacing.lg)
        .overlay(alignment: .bottomTrailing) {
            watermark
                .padding(.bottom, Spacing.md)
                .padding(.trailing, Spacing.lg)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var watermark: some View {
        HStack(spacing: 4) {
            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            Text("anubis by JT")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.primary)
        .opacity(0.4)
    }

    @Environment(\.colorScheme) private var colorScheme

    @MainActor
    private func renderImage() -> NSImage? {
        let content = exportableContent
            .frame(width: 1600)
            .environment(\.colorScheme, colorScheme)
            .environment(\.isExporting, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2.0
        return renderer.nsImage
    }

    private func copyToClipboard() {
        guard let image = renderImage() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    private func saveAsPNG() {
        guard let image = renderImage(),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else { return }

        let modelSlug = (viewModel.selectedModel?.name ?? viewModel.currentSession?.modelName ?? "benchmark")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let defaultName = "anubis-\(modelSlug)-\(timestamp).png"

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? pngData.write(to: url)
    }

    private func shareImage() {
        guard let image = renderImage() else { return }
        // Find the key window's content view to anchor the sharing picker
        guard let contentView = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [image])
        // Anchor near the top-right where the export button is
        let anchorRect = NSRect(x: contentView.bounds.maxX - 40, y: contentView.bounds.maxY - 40, width: 1, height: 1)
        picker.show(relativeTo: anchorRect, of: contentView, preferredEdge: .minY)
    }

    // MARK: - Hero Card (left)

    private var heroCard: some View {
        HStack(spacing: 0) {
            // Left half: Model + Chip
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(viewModel.selectedModel?.name ?? viewModel.currentSession?.modelName ?? "—")
                    .font(.system(size: 24, weight: .bold, design: .default))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Spacer(minLength: Spacing.xs)

                VStack(alignment: .leading, spacing: 4) {
                    Text(ChipInfo.macModelName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(chip.name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: Spacing.xs) {
                        Text("\(chip.performanceCores)P + \(chip.efficiencyCores)E")
                        if chip.gpuCores > 0 {
                            Text("·")
                                .foregroundStyle(.secondary)
                            Text("\(chip.gpuCores) GPU")
                                .font(.system(size: 16, weight: .medium))
                        }
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text("\(chip.unifiedMemoryGB) GB")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.md)

            // Right half: tok/s hero with tinted background
            VStack(spacing: Spacing.sm) {
                Spacer(minLength: 0)

                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(viewModel.formattedTokensPerSecond)
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.chartTokens)
                    Text("avg")
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.chartTokens.opacity(0.5))
                }

                HStack(spacing: Spacing.sm) {
                    if viewModel.peakTokensPerSecond > 0 {
                        Label("Peak \(viewModel.formattedPeakTokensPerSecond)", systemImage: "arrow.up")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                    if let ttft = viewModel.timeToFirstToken {
                        Label("TTFT \(Formatters.milliseconds(ttft * 1000))", systemImage: "clock")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                    if viewModel.elapsedTime > 0 {
                        Label(Formatters.duration(viewModel.elapsedTime), systemImage: "timer")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(Spacing.md)
            .background(Color.chartTokens.opacity(0.06))
        }
        .background {
            RoundedRectangle(cornerRadius: CornerRadius.lg)
                .fill(Color.cardBackgroundElevated)
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.lg)
                        .strokeBorder(Color.cardBorder, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg))
    }

    // MARK: - Metrics Card (right)

    private var metricsCard: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: Spacing.sm) {
            // Row 1: Utilization + TTFT
            expandedStat(icon: "gpu", label: "GPU", value: String(format: "%.0f%%", viewModel.gpuUtilizationPercent), color: .chartGPU, available: viewModel.hasHardwareMetrics)
            expandedStat(icon: "cpu", label: "CPU", value: String(format: "%.0f%%", viewModel.cpuUtilizationPercent), color: .chartCPU)
            expandedStat(icon: "clock", label: "TTFT", value: viewModel.timeToFirstToken.map { Formatters.milliseconds($0 * 1000) } ?? "—", color: .chartTokens)
            expandedStat(icon: "memorychip", label: "Memory", value: viewModel.formattedBackendMemory, color: .chartMemory)

            // Row 2: Power
            expandedStat(icon: "bolt.horizontal.fill", label: "GPU Power", value: viewModel.avgGPUPowerFormatted, color: .chartGPUPower, available: viewModel.hasPowerMetrics)
            expandedStat(icon: "powerplug.fill", label: "System Power", value: viewModel.avgSystemPowerFormatted, color: .chartSystemPower, available: viewModel.hasPowerMetrics)
            expandedStat(icon: "leaf.fill", label: "J/Token", value: viewModel.currentWattsPerTokenFormatted, color: .chartEfficiency, available: viewModel.hasPowerMetrics)
            expandedStat(icon: "gauge.with.dots.needle.67percent", label: "GPU Freq", value: viewModel.currentGPUFrequencyFormatted, color: .chartFrequency, available: viewModel.hasPowerMetrics)

            // Row 3: Session details
            expandedStat(icon: "number", label: "Tokens", value: viewModel.tokensGenerated > 0 ? "\(viewModel.tokensGenerated)" : "—", color: .chartTokens)
            expandedStat(icon: "arrow.up.right", label: "Peak Memory", value: viewModel.currentPeakMemory > 0 ? Formatters.bytes(viewModel.currentPeakMemory) : "—", color: .chartMemory)
            expandedStat(icon: "bolt.fill", label: "Peak GPU Power", value: viewModel.peakGpuPower > 0 ? viewModel.peakGPUPowerFormatted : "—", color: .chartGPUPower, available: viewModel.hasPowerMetrics)
            expandedStat(icon: "network", label: "Connection", value: viewModel.connectionName, color: .anubisMuted)
        }
        .cardStyle()
    }

    private func expandedStat(icon: String, label: String, value: String, color: Color, available: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(available ? value : "—")
                .font(.mono(14, weight: .semibold))
                .foregroundStyle(available && value != "—" ? .primary : .tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Chart Height

    /// Compute chart height so all rows fit without scrolling in the 3-column layout.
    /// With power: 5 rows (header, CPU/Mem/GPU, cores/power, power/wpt/freq, cpuPower)
    /// Without power: 3 rows (header, CPU/Mem/GPU, cores)
    private func expandedChartHeight(availableHeight: CGFloat) -> CGFloat {
        let totalRows: CGFloat = viewModel.hasPowerMetrics ? 5 : 3
        let padding: CGFloat = 48  // lg padding top + bottom
        let gridSpacing: CGFloat = Spacing.md * (totalRows - 1) // spacing between rows
        let usableHeight = availableHeight - padding - gridSpacing
        let perRow = usableHeight / totalRows
        // Chart area is row height minus title/label overhead (~30px)
        return max(80, perRow - 30)
    }
}

// MARK: - Process Picker Menu

/// Inline menu for selecting which process to monitor for backend metrics.
/// Shows auto-detected backend or lets user pick any process with >50MB RSS.
private struct ProcessPickerMenu: View {
    @ObservedObject var viewModel: BenchmarkViewModel
    @Environment(\.isExporting) private var isExporting

    /// 1.2s refresh keeps CPU% live without thrashing — the second tick
    /// produces the first real CPU number (calculateCPUPercent needs a
    /// baseline; the first call always returns 0).
    private let refreshTimer = Timer.publish(every: 1.2, on: .main, in: .common).autoconnect()

    /// Top N processes to show (already sorted by memory descending)
    private var topProcesses: [ProcessCandidate] {
        Array(viewModel.candidateProcesses.prefix(10))
    }

    var body: some View {
        if !isExporting {
        Menu {
            // Auto-detect option
            Button {
                viewModel.clearCustomProcess()
            } label: {
                HStack {
                    Text("Auto-detect")
                    if !viewModel.isCustomProcessActive {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            // Auto-detected backends section
            if let backendName = viewModel.currentBackendProcessName, !viewModel.isCustomProcessActive {
                Section("Detected") {
                    Label(backendName, systemImage: "checkmark.circle.fill")
                        .disabled(true)
                }
            }

            Divider()

            // Top processes by memory
            Section("Top Processes (live, sorted by memory)") {
                if topProcesses.isEmpty {
                    Text("Scanning...")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(topProcesses) { process in
                        Button {
                            viewModel.selectCustomProcess(process)
                        } label: {
                            Text(processRowLabel(for: process))
                        }
                    }
                }
            }

            Divider()

            Button {
                Task { await viewModel.refreshProcessList() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 3) {
                if viewModel.isCustomProcessActive {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text("Process: \(processDisplayName)")
                    .font(.caption2)
                    .foregroundStyle(viewModel.isCustomProcessActive ? .orange : .secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onAppear {
            if viewModel.candidateProcesses.isEmpty {
                Task { await viewModel.refreshProcessList() }
            }
        }
        .onReceive(refreshTimer) { _ in
            Task { await viewModel.refreshProcessList() }
        }
        } // if !isExporting
    }

    /// Build the single-line label for a picker row. We can't use a multi-line
    /// VStack inside a Menu Button label on macOS (the menu strips it), so we
    /// pack everything into one Text and lean on a separator dot.
    private func processRowLabel(for process: ProcessCandidate) -> String {
        let displayName: String
        if let sub = process.subtitle, !sub.isEmpty {
            displayName = "\(process.name) (\(sub))"
        } else {
            displayName = process.name
        }
        let memory = Formatters.bytes(process.memoryBytes)
        let cpu = process.cpuPercent
        // Only show CPU once it's meaningfully measured — under 1% reads as
        // baseline noise and clutters the menu.
        if cpu >= 1 {
            return "\(displayName) — \(memory) · \(Int(cpu.rounded()))% CPU"
        }
        return "\(displayName) — \(memory)"
    }

    private var processDisplayName: String {
        if let name = viewModel.currentBackendProcessName {
            return name
        }
        return "None"
    }
}

// MARK: - Live Charts View

/// Isolated chart view that observes only the BenchmarkChartStore.
/// This prevents chart data updates from invalidating the text streaming view
/// and vice versa, eliminating the main cause of streaming choppiness.
/// Shared chart grid used by LiveChartsView, ExpandedMetricsView, and SessionDetailView.
/// Single source of truth for chart names, colors, ordering, and layout.
struct ChartGrid: View {
    let data: BenchmarkChartData
    let hasHardwareMetrics: Bool
    let hasPowerMetrics: Bool
    let currentMemoryBytes: Int64
    let totalMemoryBytes: Int64
    var perCoreSnapshot: [CoreUtilization] = []
    var onExpandCores: (() -> Void)? = nil
    var gpuUtilization: Double = 0
    var onExpandGPU: (() -> Void)? = nil
    var averageTps: Double? = nil
    var isComplete: Bool = false
    var chartHeight: CGFloat = 150
    var elapsedTime: TimeInterval = 0
    /// Per-core CPU / GPU-core bar grids are live-only (not persisted per
    /// sample), so the history view disables them rather than showing empty
    /// "Waiting for data…" cards for runs that never recorded per-core data.
    var showCoreGrids: Bool = true

    private let columns = [
        GridItem(.flexible(), spacing: Spacing.sm),
        GridItem(.flexible(), spacing: Spacing.sm),
        GridItem(.flexible(), spacing: Spacing.sm)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: Spacing.sm) {
            // 3-col flow — chart order preserved; rows fill left-to-right.
            TimelineChart(
                title: "Tok/Second",
                data: data.tokensPerSecond,
                color: .chartTokens,
                unit: "tok/s",
                valueNote: isComplete ? "avg" : "live",
                displayValue: isComplete ? averageTps : nil,
                chartHeight: chartHeight
            )

            if hasHardwareMetrics {
                TimelineChart(
                    title: "GPU Utilization",
                    data: data.gpuUtilization,
                    color: .chartGPU,
                    unit: "%",
                    maxValue: 100,
                    chartHeight: chartHeight
                )
            } else {
                TimelineChart(
                    title: "CPU Utilization",
                    data: data.cpuUtilization,
                    color: .chartCPU,
                    unit: "%",
                    maxValue: 100,
                    chartHeight: chartHeight
                )
            }

            if hasHardwareMetrics {
                TimelineChart(
                    title: "CPU Utilization",
                    data: data.cpuUtilization,
                    color: .chartCPU,
                    unit: "%",
                    maxValue: 100,
                    chartHeight: chartHeight
                )
            }

            MemoryTimelineChart(
                title: "Tot. Memory",
                data: data.memoryUtilization,
                currentBytes: currentMemoryBytes,
                totalBytes: totalMemoryBytes,
                color: .chartMemory,
                chartHeight: chartHeight
            )

            // Gate purely on capability (IOReport/power available), not on
            // whether samples have arrived yet — each card renders its own
            // empty-state placeholder before data, so the grid layout is
            // consistent before and during a run.
            if hasPowerMetrics {
                if showCoreGrids {
                    CoreUtilizationGrid(snapshot: perCoreSnapshot) {
                        onExpandCores?()
                    }

                    GPUCoreGrid(gpuUtilization: gpuUtilization) {
                        onExpandGPU?()
                    }
                }

                TimelineChart(
                    title: "GPU Power",
                    data: data.gpuPower,
                    color: .chartGPUPower,
                    unit: "W",
                    chartHeight: chartHeight
                )

                TimelineChart(
                    title: "System Power",
                    data: data.systemPower,
                    color: .chartSystemPower,
                    unit: "W",
                    chartHeight: chartHeight
                )

                TimelineChart(
                    title: "GPU Frequency",
                    data: data.gpuFrequency,
                    color: .chartFrequency,
                    unit: "MHz",
                    chartHeight: chartHeight
                )

                TimelineChart(
                    title: "Energy per Token",
                    data: data.wattsPerToken,
                    color: .chartEfficiency,
                    unit: "J/tok",
                    chartHeight: chartHeight
                )

                TimelineChart(
                    title: "CPU Power",
                    data: data.cpuPower,
                    color: .chartCPUPower,
                    unit: "W",
                    chartHeight: chartHeight
                )

                RunTimeCard(elapsedTime: elapsedTime, isComplete: isComplete, chartHeight: chartHeight)
            }

            // Platform without power capability — still show the core grids
            // (they render their own empty state until data arrives).
            if !hasPowerMetrics && showCoreGrids {
                CoreUtilizationGrid(snapshot: perCoreSnapshot) {
                    onExpandCores?()
                }

                GPUCoreGrid(gpuUtilization: gpuUtilization) {
                    onExpandGPU?()
                }
            }
        }
    }
}

/// Fills the trailing slot in the chart grid with the current/total run time —
/// matches chart card height so the last row stays visually balanced.
struct RunTimeCard: View {
    let elapsedTime: TimeInterval
    let isComplete: Bool
    let chartHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Run Time")
                    .font(.headline)
                Spacer()
                Text(isComplete ? "total" : "live")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.6))
            }

            ZStack {
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .fill(Color.emptyStateBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .strokeBorder(Color.cardBorder, lineWidth: 1)
                    }

                VStack(spacing: Spacing.xs) {
                    Image(systemName: isComplete ? "checkmark.circle.fill" : "timer")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(isComplete ? Color.anubisSuccess : Color.anubisAccent)
                    Text(Formatters.duration(elapsedTime))
                        .font(.mono(28, weight: .semibold))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                        .monospacedDigit()
                }
            }
            .frame(height: chartHeight)
        }
        .cardStyle()
    }
}

/// Live chart wrapper that observes BenchmarkChartStore independently,
/// isolating chart re-renders from the main view's body.
private struct LiveChartsView: View {
    @ObservedObject var chartStore: BenchmarkChartStore
    let isRunning: Bool
    let hasHardwareMetrics: Bool
    let hasPowerMetrics: Bool
    let currentMemoryBytes: Int64
    let totalMemoryBytes: Int64
    var perCoreSnapshot: [CoreUtilization] = []
    var onExpandCores: (() -> Void)? = nil
    var gpuUtilization: Double = 0
    var onExpandGPU: (() -> Void)? = nil
    var averageTps: Double = 0
    var chartHeight: CGFloat = 150
    var elapsedTime: TimeInterval = 0

    var body: some View {
        ChartGrid(
            data: chartStore.chartData,
            hasHardwareMetrics: hasHardwareMetrics,
            hasPowerMetrics: hasPowerMetrics,
            currentMemoryBytes: currentMemoryBytes,
            totalMemoryBytes: totalMemoryBytes,
            perCoreSnapshot: perCoreSnapshot,
            onExpandCores: onExpandCores,
            gpuUtilization: gpuUtilization,
            onExpandGPU: onExpandGPU,
            averageTps: averageTps,
            isComplete: !isRunning,
            chartHeight: chartHeight,
            elapsedTime: elapsedTime
        )
    }
}

// MARK: - Pull Model Sheet

private struct BenchmarkPullModelSheet: View {
    @ObservedObject var viewModel: BenchmarkViewModel

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

            if !viewModel.isPulling {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Popular Models")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: Spacing.xs) {
                        pullSuggestion("llama3.2:3b")
                        pullSuggestion("qwen2.5:7b")
                        pullSuggestion("deepseek-r1:8b")
                        pullSuggestion("phi4:14b")
                    }
                }
            }
        }
        .padding(Spacing.lg)
        .frame(width: 400)
        .onDisappear {
            // Safety net: any path that dismisses the sheet while
            // a pull is in flight should also cancel the download,
            // not leave it running in the background. Cancel button
            // already routes through cancelPull(); this catches the
            // window-close / external-binding-flip cases.
            if viewModel.isPulling {
                viewModel.cancelPull()
            }
        }
    }

    private func pullSuggestion(_ name: String) -> some View {
        Button(name) {
            viewModel.pullModelName = name
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.caption)
    }
}

// MARK: - Leaderboard Pill Button

/// Toolbar affordance that surfaces the upload state of the most-
/// recently completed run. Replaces the previous plain "Leaderboard"
/// button with a small state machine driven by the viewModel:
///
///   idle             — no completed session, button disabled
///   uploadable       — completed run, never submitted → icon pulses,
///                      label gets a subtle "Submit" lead so users
///                      who don't know about the leaderboard at least
///                      see it as actionable
///   in-progress      — auto-submit or manual upload running →
///                      ProgressView replaces the icon
///   submitted        — flipped after a successful upload → checkmark
///                      icon, green tint, tooltip says when
///   failed           — auto-submit failure → triangle.exclamationmark,
///                      tooltip carries the server error
///
/// Clicking always opens the existing LeaderboardUploadView sheet, so
/// the user can re-submit (or set a display name on first launch)
/// without losing the existing flow.
private struct LeaderboardPillButton: View {
    @ObservedObject var viewModel: BenchmarkViewModel
    @Binding var showLeaderboardUpload: Bool

    private enum PillState {
        case idle, uploadable, submitting, submitted, failed
    }

    private var state: PillState {
        if viewModel.leaderboardSubmissionInProgress { return .submitting }
        guard viewModel.currentSession?.status == .completed else { return .idle }
        if viewModel.currentSessionLeaderboardSubmitted { return .submitted }
        if viewModel.lastLeaderboardSubmissionError != nil { return .failed }
        return .uploadable
    }

    var body: some View {
        Button {
            showLeaderboardUpload = true
        } label: {
            switch state {
            case .submitting:
                Label {
                    Text("Submitting…")
                } icon: {
                    ProgressView().controlSize(.mini)
                }
            case .submitted:
                Label("Submitted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Label("Retry Submit", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .uploadable:
                // Note: a continuously-pulsing .symbolEffect ran the
                // CoreAnimation transaction loop forever, which made
                // scroll feel like 30fps everywhere because every
                // scroll commit had to flush both the scroll delta
                // and the animation frame through the GPU. A label
                // change + bold color is enough to draw the eye
                // without burning a CA transaction per display tick.
                Label("Submit to Leaderboard", systemImage: "globe.badge.chevron.backward")
                    .foregroundStyle(.blue)
                    .fontWeight(.semibold)
            case .idle:
                Label("Leaderboard", systemImage: "globe.badge.chevron.backward")
            }
        }
        .disabled(state == .idle || state == .submitting)
        .help(tooltip)
    }

    private var tooltip: String {
        switch state {
        case .idle:
            return "Run a benchmark first, then submit it to the community leaderboard"
        case .uploadable:
            if viewModel.autoSubmitLeaderboardEnabled && viewModel.leaderboardDisplayName == nil {
                return "Auto-submit is on but no display name is set. Click to set one and submit this run."
            }
            return "Add this run to the community leaderboard at devpadapp.com/leaderboard.html"
        case .submitting:
            return "Submitting this run to the community leaderboard…"
        case .submitted:
            return "Submitted ✓ — click to view the sheet or re-submit"
        case .failed:
            return "Last submission failed: \(viewModel.lastLeaderboardSubmissionError ?? "unknown error"). Click to retry."
        }
    }
}

// MARK: - Browse Ollama Library Sheet

/// Sheet that scrapes ollama.com/library (+ /search?q=) and lets the
/// user pick a model + size to pull. Always-fresh catalog with zero
/// curation maintenance; pulls run through the existing
/// pullModel() / showPullSheet plumbing so progress UI is unified.
private struct BrowseOllamaLibrarySheet: View {
    @ObservedObject var viewModel: BenchmarkViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    /// Debounce token — restart the work item on every keystroke
    /// so we only fetch when the user pauses typing.
    @State private var searchDebounce: Task<Void, Never>?
    /// Names of locally-installed models (lowercased base names),
    /// so we can show an "Installed" badge on entries the user
    /// already has. Snapshotted on sheet appear.
    @State private var installedNames: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            content
        }
        .frame(width: 720, height: 560)
        .task {
            // Snapshot installed model base-names so we can mark
            // entries the user already has.
            installedNames = Set(viewModel.availableModels.compactMap {
                $0.name.split(separator: ":").first.map { String($0).lowercased() }
            })
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "books.vertical.fill")
                .foregroundStyle(.blue)
            Text("Browse Ollama Models")
                .font(.headline)
            Spacer()
            Button {
                Task { await viewModel.reloadLibrary(forceRefresh: true) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Re-fetch from ollama.com, bypass the 24-hour cache")
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(Spacing.md)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                "Search ollama.com/library (e.g. \"qwen\", \"reasoning\", \"code\")…",
                text: $searchText
            )
            .textFieldStyle(.plain)
            .onSubmit { fireSearch() }
            .onChange(of: searchText) { _, _ in
                // 300 ms debounce so we don't fetch on every keystroke.
                searchDebounce?.cancel()
                searchDebounce = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if !Task.isCancelled { fireSearch() }
                }
            }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    fireSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    private func fireSearch() {
        viewModel.librarySearchQuery = searchText
        Task { await viewModel.reloadLibrary(forceRefresh: false) }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.libraryLoading && viewModel.libraryEntries.isEmpty {
            VStack(spacing: Spacing.sm) {
                Spacer()
                ProgressView()
                Text("Fetching ollama.com/library…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.libraryError {
            VStack(spacing: Spacing.sm) {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text("Couldn't load the Ollama library")
                    .font(.headline)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await viewModel.reloadLibrary(forceRefresh: true) }
                }
                .buttonStyle(.bordered)
                .padding(.top, Spacing.xs)
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.libraryEntries.isEmpty {
            VStack(spacing: Spacing.sm) {
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text(searchText.isEmpty ? "No models returned." : "No matches for \"\(searchText)\".")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: Spacing.sm) {
                    ForEach(viewModel.libraryEntries) { entry in
                        LibraryEntryRow(
                            entry: entry,
                            isInstalled: installedNames.contains(entry.name.lowercased()),
                            onPull: { size in
                                viewModel.pullFromLibrary(entry, size: size)
                            }
                        )
                    }
                }
                .padding(Spacing.md)
            }
        }
    }
}

/// One card row in the browse sheet. Layout:
///   [name (installed-badge if any)]                    [refresh-time, pull-count]
///   [description]
///   [capability chips]  [size buttons]
private struct LibraryEntryRow: View {
    let entry: OllamaLibraryEntry
    let isInstalled: Bool
    let onPull: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.name)
                    .font(.system(size: 15, weight: .semibold))
                if isInstalled {
                    Text("Installed")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.18), in: Capsule())
                        .foregroundStyle(.green)
                }
                Spacer()
                if !entry.pullCount.isEmpty {
                    Label(entry.pullCount, systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !entry.updated.isEmpty {
                    Text(entry.updated)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if !entry.description.isEmpty {
                Text(entry.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                ForEach(entry.capabilities, id: \.self) { cap in
                    Text(cap)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.indigo.opacity(0.15), in: Capsule())
                        .foregroundStyle(.indigo)
                }
                Spacer()
                if entry.sizes.isEmpty {
                    // No size variants exposed — pull bare name.
                    Button("Pull") { onPull(nil) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    ForEach(entry.sizes, id: \.self) { size in
                        Button(size) { onPull(size) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Pull \(entry.name):\(size)")
                    }
                }
            }
        }
        .padding(Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .fill(Color.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .strokeBorder(Color.cardBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - oMLX Model Browser

/// Browse + download MLX models from oMLX's HuggingFace integration. Mirrors
/// the Ollama library browser, but search/recommended/download all go through
/// oMLX's admin HF endpoints (poll-based download progress).
private struct OMLXModelBrowserSheet: View {
    @ObservedObject var viewModel: BenchmarkViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var searchDebounce: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            content
            if viewModel.isDownloadingOMLXModel {
                Divider()
                downloadBar
            }
        }
        .frame(width: 580, height: 620)
    }

    private var header: some View {
        HStack {
            Image(systemName: "square.and.arrow.down.on.square")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Browse oMLX Models").font(.headline)
                Text("MLX models from HuggingFace, downloaded by your oMLX server")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(Spacing.md)
    }

    private var searchBar: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search HuggingFace (MLX) — leave empty for trending", text: $searchText)
                .textFieldStyle(.plain)
                .onChange(of: searchText) { _, _ in scheduleSearch() }
            if !searchText.isEmpty {
                Button { searchText = ""; fireSearch() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.omlxBrowseLoading && viewModel.omlxBrowseModels.isEmpty {
            Spacer()
            ProgressView().controlSize(.large)
            Spacer()
        } else if let err = viewModel.omlxBrowseError {
            Spacer()
            VStack(spacing: Spacing.sm) {
                Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.orange)
                Text(err).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { Task { await viewModel.reloadOMLXBrowse() } }
                    .buttonStyle(.bordered)
            }
            .padding()
            Spacer()
        } else if viewModel.omlxBrowseModels.isEmpty {
            Spacer()
            Text(searchText.isEmpty ? "No models available." : "No matches for \"\(searchText)\".")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.omlxBrowseModels) { model in
                        OMLXModelRow(
                            model: model,
                            isInstalled: viewModel.isOMLXModelInstalled(model.repoId),
                            isDownloadingThis: viewModel.omlxDownloadingRepo == model.repoId,
                            downloadInFlight: viewModel.isDownloadingOMLXModel,
                            onDownload: { viewModel.downloadOMLXModel(model.repoId) }
                        )
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    private var downloadBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(viewModel.omlxDownloadingRepo ?? "")
                    .font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(Int(viewModel.omlxDownloadProgress * 100))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Cancel") { viewModel.cancelOMLXDownload() }
                    .buttonStyle(.borderless).controlSize(.small)
            }
            ProgressView(value: viewModel.omlxDownloadProgress)
            Text(viewModel.omlxDownloadStatus).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(Spacing.md)
    }

    private func scheduleSearch() {
        searchDebounce?.cancel()
        searchDebounce = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            fireSearch()
        }
    }

    private func fireSearch() {
        viewModel.omlxBrowseQuery = searchText
        Task { await viewModel.reloadOMLXBrowse() }
    }
}

private struct OMLXModelRow: View {
    let model: OMLXHFModel
    let isInstalled: Bool
    let isDownloadingThis: Bool
    let downloadInFlight: Bool
    let onDownload: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 10) {
                    if !model.sizeFormatted.isEmpty {
                        metaChip("internaldrive", model.sizeFormatted)
                    }
                    if let params = model.paramsFormatted {
                        metaChip("cpu", params)
                    }
                    if model.downloads > 0 {
                        metaChip("arrow.down.circle", Formatters.compactCount(model.downloads))
                    }
                    if model.likes > 0 {
                        metaChip("heart", "\(model.likes)")
                    }
                }
            }
            Spacer()
            if isInstalled {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else if isDownloadingThis {
                ProgressView().controlSize(.small)
            } else {
                Button("Download", action: onDownload)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(downloadInFlight)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    private func metaChip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.caption2)
        }
        .foregroundStyle(.secondary)
    }
}
