//
//  BenchmarkView.swift
//  anubis
//
//  Created on 2026-01-25.
//

import SwiftUI
import Charts
import AppKit
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
    @StateObject private var viewModel: BenchmarkViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var showSystemPrompt = false
    @State private var showParameters = false
    @State private var showPerformance = false
    @State private var showLeaderboardUpload = false

    init(
        inferenceService: InferenceService,
        metricsService: MetricsService,
        databaseManager: DatabaseManager
    ) {
        _viewModel = StateObject(wrappedValue: BenchmarkViewModel(
            inferenceService: inferenceService,
            metricsService: metricsService,
            databaseManager: databaseManager
        ))
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

            // Right panel - Metrics Dashboard (~70% default)
            ScrollView {
                VStack(spacing: Spacing.md) {
                    metricsCardsSection
                    detailedStatsSection
                    chartsSection
                }
                .padding(Spacing.md)
            }
            .frame(minWidth: 300)
            .layoutPriority(1)
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

                Button {
                    showLeaderboardUpload = true
                } label: {
                    Label("Leaderboard", systemImage: "globe.badge.chevron.backward")
                }
                .disabled(viewModel.currentSession?.status != .completed)
                .help("Upload to community leaderboard")

                Button {
                    viewModel.openExpandedMetricsWindow()
                } label: {
                    Label("Expand Results", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Expand metrics dashboard")

                Button {
                    viewModel.openHistoryWindow()
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }

                Button {
                    viewModel.startPull()
                } label: {
                    Label("Pull Model", systemImage: "arrow.down.circle")
                }
                .help("Pull a model from Ollama")
            }
        }
        .onDisappear {
            viewModel.closeAuxiliaryWindows()
        }
        .sheet(isPresented: $showLeaderboardUpload) {
            if let session = viewModel.currentSession {
                LeaderboardUploadView(session: session)
            }
        }
        .sheet(isPresented: $viewModel.showPullSheet) {
            BenchmarkPullModelSheet(viewModel: viewModel)
        }
        .task {
            await viewModel.loadModels()
            await viewModel.loadRecentSessions()
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

                    // Refresh models button
                    Button {
                        Task { await viewModel.loadModels() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh model list")
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
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.anubisWarning)
                    Text(error.localizedDescription)
                        .font(.caption)
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
                .padding(.top, Spacing.xxs)
            } label: {
                HStack {
                    Text("Performance")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !viewModel.streamResponse || !viewModel.showLiveCharts {
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

    // MARK: - Metrics Cards Section

    private var metricsCardsSection: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: Spacing.sm) {
            // Row 1: Performance
            CompactMetricsCard(
                title: "Tokens/sec",
                value: viewModel.formattedTokensPerSecond,
                icon: "bolt.fill",
                color: .chartTokens,
                subtitle: viewModel.peakTokensPerSecond > 0 ? "Peak: \(viewModel.formattedPeakTokensPerSecond)" : nil,
                help: "Average tokens generated per second."
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
                value: viewModel.timeToFirstToken.map { Formatters.milliseconds($0 * 1000) } ?? "—",
                icon: "clock.arrow.circlepath",
                color: .chartTokens,
                help: "Time to first token. Includes model loading if cold start."
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
                title: "W/Token",
                value: viewModel.currentWattsPerTokenFormatted,
                icon: "leaf.fill",
                color: .chartEfficiency,
                available: viewModel.hasPowerMetrics,
                help: "Power efficiency: avg system watts ÷ tokens/sec."
            )

            CompactMetricsCard(
                title: "Total Memory",
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
                    onExpandGPU: { viewModel.openGPUDetailWindow() }
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

    // MARK: - Detailed Stats Section

    private var detailedStatsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Session Details")
                .font(.headline)
                .padding(.bottom, Spacing.xs)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: Spacing.sm) {
                // Row 1: Latency / Load / Context / GPU Frequency
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
                    value: viewModel.currentPeakMemory > 0
                        ? Formatters.bytes(viewModel.currentPeakMemory)
                        : viewModel.currentSession?.peakMemoryBytes.map { Formatters.bytes($0) } ?? "—",
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

                // Row 3: Thermal / Peak GPU Power / Avg W/Token / Connection
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
                    title: "Avg W/Token",
                    value: viewModel.currentSession?.avgWattsPerToken.map { String(format: "%.2f W/tok", $0) } ?? "—",
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

            // Chip info + backend summary line
            HStack(spacing: Spacing.sm) {
                Text(viewModel.selectedModel?.name ?? viewModel.currentSession?.modelName ?? "—")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

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
        }
        .padding(Spacing.sm)
        .frame(width: 260)
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let icon, let color {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                        .foregroundStyle(color)
                }
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.mono(13, weight: .medium))
                .foregroundStyle(value == "—" ? .tertiary : .primary)
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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        // Skip layout for offscreen text — critical for long streaming responses
        textView.layoutManager?.allowsNonContiguousLayout = true

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

        // No change — skip entirely (O(1) integer check, not O(n) string comparison)
        if newNSLength == coordinator.renderedUTF16Length {
            return
        }

        // Incremental append — only the new delta via NSTextStorage
        let wasAtBottom = isScrolledToBottom(scrollView)
        let delta = (text as NSString).substring(from: coordinator.renderedUTF16Length)

        if let storage = textView.textStorage {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor
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

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.md) {
                // Top row: Hero header card | Metrics card
                LazyVGrid(columns: topColumns, spacing: Spacing.md) {
                    heroCard
                    metricsCard
                }

                // Charts
                chartsSection
            }
            .padding(Spacing.lg)
        }
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
                LeaderboardUploadView(session: session)
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

    /// The content rendered for export — same layout as the live view but with a watermark overlay.
    private var exportableContent: some View {
        VStack(spacing: Spacing.md) {
            LazyVGrid(columns: topColumns, spacing: Spacing.md) {
                heroCard
                metricsCard
            }
            chartsSection
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
                    Text("")
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.chartTokens.opacity(0.7))
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
            expandedStat(icon: "leaf.fill", label: "W/Token", value: viewModel.currentWattsPerTokenFormatted, color: .chartEfficiency, available: viewModel.hasPowerMetrics)
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

    // MARK: - Charts Section

    private var chartsSection: some View {
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
            onExpandGPU: { viewModel.openGPUDetailWindow() }
        )
    }
}

// MARK: - Process Picker Menu

/// Inline menu for selecting which process to monitor for backend metrics.
/// Shows auto-detected backend or lets user pick any process with >50MB RSS.
private struct ProcessPickerMenu: View {
    @ObservedObject var viewModel: BenchmarkViewModel
    @Environment(\.isExporting) private var isExporting

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
            Section("Top Processes by Memory") {
                if topProcesses.isEmpty {
                    Text("Scanning...")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(topProcesses) { process in
                        Button {
                            viewModel.selectCustomProcess(process)
                        } label: {
                            Text("\(process.name) — \(Formatters.bytes(process.memoryBytes))")
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
        } // if !isExporting
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

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        LazyVGrid(columns: columns, spacing: Spacing.md) {
            // Row 1: Tokens/sec | GPU Utilization
            TimelineChart(
                title: "Tokens per Second",
                data: data.tokensPerSecond,
                color: .chartTokens,
                unit: "tok/s"
            )

            if hasHardwareMetrics {
                TimelineChart(
                    title: "GPU Utilization",
                    data: data.gpuUtilization,
                    color: .chartGPU,
                    unit: "%",
                    maxValue: 100
                )
            } else {
                TimelineChart(
                    title: "CPU Utilization",
                    data: data.cpuUtilization,
                    color: .chartCPU,
                    unit: "%",
                    maxValue: 100
                )
            }

            // Row 2: CPU Utilization | Total Memory
            if hasHardwareMetrics {
                TimelineChart(
                    title: "CPU Utilization",
                    data: data.cpuUtilization,
                    color: .chartCPU,
                    unit: "%",
                    maxValue: 100
                )
            }

            MemoryTimelineChart(
                title: "Total Memory",
                data: data.memoryUtilization,
                currentBytes: currentMemoryBytes,
                totalBytes: totalMemoryBytes,
                color: .chartMemory
            )

            // Row 3: CPU Cores | GPU Cores
            if hasPowerMetrics && data.hasPowerData {
                if !perCoreSnapshot.isEmpty {
                    CoreUtilizationGrid(snapshot: perCoreSnapshot) {
                        onExpandCores?()
                    }
                }

                GPUCoreGrid(gpuUtilization: gpuUtilization) {
                    onExpandGPU?()
                }

                // Row 4: GPU Power | System Power
                TimelineChart(
                    title: "GPU Power",
                    data: data.gpuPower,
                    color: .chartGPUPower,
                    unit: "W"
                )

                TimelineChart(
                    title: "System Power",
                    data: data.systemPower,
                    color: .chartSystemPower,
                    unit: "W"
                )

                // Row 5: GPU Frequency | Watts/Token
                TimelineChart(
                    title: "GPU Frequency",
                    data: data.gpuFrequency,
                    color: .chartFrequency,
                    unit: "MHz"
                )

                TimelineChart(
                    title: "Watts per Token",
                    data: data.wattsPerToken,
                    color: .chartEfficiency,
                    unit: "W/tok"
                )

                // Row 6: CPU Power
                TimelineChart(
                    title: "CPU Power",
                    data: data.cpuPower,
                    color: .chartCPUPower,
                    unit: "W"
                )
            }

            // Show core grids even without power metrics
            if !hasPowerMetrics || !data.hasPowerData {
                if !perCoreSnapshot.isEmpty {
                    CoreUtilizationGrid(snapshot: perCoreSnapshot) {
                        onExpandCores?()
                    }
                }

                GPUCoreGrid(gpuUtilization: gpuUtilization) {
                    onExpandGPU?()
                }
            }
        }
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
            onExpandGPU: onExpandGPU
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
