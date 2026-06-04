//
//  SessionHistoryView.swift
//  anubis
//
//  Created on 2026-01-25.
//

import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import GRDB

/// View displaying benchmark session history (presented as a window)
struct SessionHistoryView: View {
    @ObservedObject var viewModel: BenchmarkViewModel
    /// Multi-select set of session ids. cmd-click toggles, shift-click
    /// range-selects natively in SwiftUI's List. When exactly one is
    /// selected the detail panel binds to it; bulk-delete acts on the
    /// whole set.
    @State private var selectedSessionIds: Set<Int64> = []
    @State private var showingClearConfirmation = false
    @State private var showingBulkDeleteConfirmation = false
    @State private var showingExportOptions = false
    @State private var exportedFileURL: URL?

    // Filters & pagination (issue #26 — users couldn't see past 20 rows,
    // had no way to filter or delete selectively without "Clear All").
    @State private var filterModel: String = ""        // "" = All
    @State private var filterBackend: String = ""
    @State private var filterStatus: String = ""       // raw value of BenchmarkStatus
    @State private var fetchLimit: Int = 200           // 50 / 200 / 500 / .max (All)

    /// Sentinel that maps to "fetch everything". Real value is capped
    /// inside the DB call so we don't accidentally hold a 100k-row
    /// array in memory if someone has been heavy on group runs.
    private static let allRecordsSentinel = 100_000

    private var runningSessionCount: Int {
        filteredSessions.filter { $0.status == .running }.count
    }

    /// Sessions after applying the model / backend / status filters.
    /// Recomputed on every render — cheap at ≤500 rows, no need to
    /// cache.
    private var filteredSessions: [BenchmarkSession] {
        viewModel.recentSessions.filter { s in
            if !filterModel.isEmpty   && s.modelName != filterModel     { return false }
            if !filterBackend.isEmpty && s.backend   != filterBackend   { return false }
            if !filterStatus.isEmpty  && s.status.rawValue != filterStatus { return false }
            return true
        }
    }

    private var hasActiveFilters: Bool {
        !filterModel.isEmpty || !filterBackend.isEmpty || !filterStatus.isEmpty
    }

    private var uniqueModels: [String] {
        Array(Set(viewModel.recentSessions.map { $0.modelName }.filter { !$0.isEmpty })).sorted()
    }
    private var uniqueBackends: [String] {
        Array(Set(viewModel.recentSessions.map { $0.backend }.filter { !$0.isEmpty })).sorted()
    }

    /// The single session shown in the detail pane. Bound from the
    /// multi-select set: when exactly one row is highlighted, that's
    /// the detail; otherwise nothing is shown.
    private var sessionForDetail: BenchmarkSession? {
        guard selectedSessionIds.count == 1, let id = selectedSessionIds.first else { return nil }
        return viewModel.recentSessions.first(where: { $0.id == id })
    }

    /// Filtered ids — what "Select All Filtered" populates and what the
    /// selection bar's count reads against when no manual selection has
    /// been made.
    private var filteredIds: [Int64] {
        filteredSessions.compactMap { $0.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Custom title bar
            HStack {
                Text("Benchmark History")
                    .font(.headline)
                Spacer()

                // Clean up running sessions
                if runningSessionCount > 0 {
                    Button {
                        Task {
                            await viewModel.cleanupRunningSessions()
                        }
                    } label: {
                        Label("Mark \(runningSessionCount) Running as Cancelled", systemImage: "xmark.circle")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Export
                Menu {
                    Button {
                        exportAllSessions()
                    } label: {
                        Label("Export All Sessions (CSV)", systemImage: "tablecells")
                    }
                    .disabled(viewModel.recentSessions.isEmpty)

                    if let session = sessionForDetail {
                        Button {
                            Task {
                                await exportSelectedSession(session)
                            }
                        } label: {
                            Label("Export Selected Session", systemImage: "doc.text")
                        }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Select All Filtered — populates the multi-select set
                // with whatever rows match the active filters. Lets users
                // "filter to cancelled, select all, delete" without N
                // right-click cycles. Hidden when nothing is loaded.
                if !filteredSessions.isEmpty {
                    Button {
                        if selectedSessionIds.count == filteredIds.count && !filteredIds.isEmpty {
                            selectedSessionIds.removeAll()
                        } else {
                            selectedSessionIds = Set(filteredIds)
                        }
                    } label: {
                        Label(
                            selectedSessionIds.count == filteredIds.count && !filteredIds.isEmpty
                                ? "Deselect All"
                                : "Select All\(hasActiveFilters ? " Filtered" : "")",
                            systemImage: "checkmark.circle"
                        )
                        .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Delete selected (bulk) — appears when ≥1 row is in
                // the multi-select set. Distinct from "Clear All" so
                // people can prune subsets without nuking everything.
                if !selectedSessionIds.isEmpty {
                    Button(role: .destructive) {
                        showingBulkDeleteConfirmation = true
                    } label: {
                        Label("Delete \(selectedSessionIds.count) Selected", systemImage: "trash")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }

                // Clear all
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Label("Clear All", systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Divider()
                    .frame(height: 20)
                    .padding(.horizontal, Spacing.sm)

                Button("Done") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(.bar)

            Divider()

            // Filter bar
            filterBar
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.4))

            Divider()

            // Main content
            HSplitView {
                // Session List
                sessionList
                    .frame(minWidth: 320, idealWidth: 320, maxWidth: 450)

                // Session Detail (only when exactly one row is selected)
                if let session = sessionForDetail {
                    SessionDetailView(session: session, viewModel: viewModel)
                        .frame(minWidth: 480)
                } else {
                    emptyDetail
                        .frame(minWidth: 400)
                }
            }
        }
        .confirmationDialog(
                "Clear All History?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All Sessions", role: .destructive) {
                    Task {
                        await viewModel.deleteAllSessions()
                        selectedSessionIds.removeAll()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete every benchmark session and its sample data — including any not currently shown by the active filters or row limit.")
            }
        .frame(minWidth: 600, minHeight: 400)
        .task {
            await viewModel.loadRecentSessions(limit: fetchLimit)
            if selectedSessionIds.isEmpty, let latestId = filteredSessions.first?.id {
                selectedSessionIds = [latestId]
            }
        }
        .onChange(of: fetchLimit) { _, newLimit in
            Task { await viewModel.loadRecentSessions(limit: newLimit) }
        }
        .confirmationDialog(
            "Delete \(selectedSessionIds.count) selected session\(selectedSessionIds.count == 1 ? "" : "s")?",
            isPresented: $showingBulkDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedSessionIds.count)", role: .destructive) {
                let toDelete = selectedSessionIds
                Task {
                    await viewModel.deleteSessions(ids: toDelete, reloadLimit: fetchLimit)
                    selectedSessionIds.removeAll()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the selected sessions and their sample data. The other \(viewModel.recentSessions.count - selectedSessionIds.count) sessions and any rows outside the current filter remain untouched.")
        }
    }

    /// Filter + pagination strip that sits above the split-view.
    /// Models / Backends are derived from currently-loaded sessions so
    /// the dropdowns auto-populate without a separate query.
    private var filterBar: some View {
        HStack(spacing: Spacing.sm) {
            Picker("", selection: $filterModel) {
                Text("All Models").tag("")
                ForEach(uniqueModels, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 200)

            Picker("", selection: $filterBackend) {
                Text("All Backends").tag("")
                ForEach(uniqueBackends, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 160)

            Picker("", selection: $filterStatus) {
                Text("Any Status").tag("")
                Text("Completed").tag("completed")
                Text("Failed").tag("failed")
                Text("Cancelled").tag("cancelled")
                Text("Running").tag("running")
            }
            .labelsHidden()
            .frame(maxWidth: 140)

            if hasActiveFilters {
                Button("Clear") {
                    filterModel = ""
                    filterBackend = ""
                    filterStatus = ""
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            Spacer()

            Text("Show:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: $fetchLimit) {
                Text("50").tag(50)
                Text("200").tag(200)
                Text("500").tag(500)
                Text("All").tag(Self.allRecordsSentinel)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
        }
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            List(filteredSessions, selection: $selectedSessionIds) { session in
                SessionRow(session: session)
                    .tag(session.id ?? -1)
                    .background(DoubleClickHandler {
                        viewModel.openSessionDetailTab(session: session)
                    })
                    .contextMenu {
                        Button {
                            viewModel.openSessionDetailTab(session: session)
                        } label: {
                            Label("Open in Tab", systemImage: "macwindow.badge.plus")
                        }

                        if session.status == .running {
                            Button {
                                Task {
                                    await viewModel.markSessionCancelled(session)
                                }
                            } label: {
                                Label("Mark as Cancelled", systemImage: "xmark.circle")
                            }
                        }

                        // Context-menu delete behaviour: if the right-clicked
                        // row is part of an existing multi-selection, treat it
                        // as a bulk-delete request for the whole selection.
                        // If the click is on a row outside the current
                        // selection, delete only that one row.
                        if let id = session.id, selectedSessionIds.contains(id), selectedSessionIds.count > 1 {
                            Button(role: .destructive) {
                                showingBulkDeleteConfirmation = true
                            } label: {
                                Label("Delete \(selectedSessionIds.count) Selected", systemImage: "trash")
                            }
                        } else {
                            Button(role: .destructive) {
                                Task {
                                    await viewModel.deleteSession(session)
                                    if let id = session.id {
                                        selectedSessionIds.remove(id)
                                    }
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
            }
            .listStyle(.inset)

            // Bottom status bar
            HStack {
                if hasActiveFilters {
                    Text("\(filteredSessions.count) of \(viewModel.recentSessions.count) sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(viewModel.recentSessions.count) sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if runningSessionCount > 0 {
                    Text("• \(runningSessionCount) running")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(.bar)
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Select a session to view details")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Export Methods

    private func exportAllSessions() {
        let csv = ExportService.exportSessionsToCSV(viewModel.recentSessions)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let filename = "anubis_sessions_\(dateFormatter.string(from: Date())).csv"

        showSavePanel(content: csv, filename: filename, contentType: .commaSeparatedText)
    }

    private func exportSelectedSession(_ session: BenchmarkSession) async {
        let samples = await viewModel.loadSamples(for: session)
        let report = ExportService.exportSessionReport(session, samples: samples)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let safeName = session.modelName.replacingOccurrences(of: "/", with: "-")
        let filename = "anubis_\(safeName)_\(dateFormatter.string(from: session.startedAt)).md"

        showSavePanel(content: report, filename: filename, contentType: .plainText)
    }

    private func showSavePanel(content: String, filename: String, contentType: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true

        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    print("Failed to export: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: BenchmarkSession

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(session.modelName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                StatusBadge(status: session.status)
            }

            HStack(spacing: Spacing.sm) {
                // Connection badge with subtle styling
                Text(session.backend)
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

                if let quant = session.modelQuantization {
                    Text(quant)
                        .font(.caption2.weight(.medium).monospaced())
                        .foregroundStyle(.secondary)
                }

                if let format = session.modelFormat {
                    Text(format)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(format == "MLX" ? Color.purple : Color.green)
                }

                if let tps = session.tokensPerSecond {
                    HStack(spacing: 3) {
                        if session.hasSuspiciousTiming {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        }
                        Text(Formatters.tokensPerSecond(tps))
                            .font(.mono(11, weight: .medium))
                            .foregroundStyle(Color.chartTokens)
                    }
                    .help(session.hasSuspiciousTiming
                          ? "Backend did not stream incrementally — tok/s reflects burst-decode time, not real generation time."
                          : "")
                }

                Spacer()

                Text(Formatters.relativeDate(session.startedAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: BenchmarkStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .shadow(color: statusColor.opacity(0.5), radius: 2)
            Text(status.rawValue.capitalized)
        }
        .badgeStyle(color: statusColor)
    }

    private var statusColor: Color {
        switch status {
        case .completed: return .anubisSuccess
        case .running: return .accentColor
        case .failed: return .anubisError
        case .cancelled: return .anubisWarning
        }
    }
}

// MARK: - Session Detail View

struct SessionDetailView: View {
    let session: BenchmarkSession
    @ObservedObject var viewModel: BenchmarkViewModel
    @State private var samples: [BenchmarkSample] = []
    @State private var statistics: SampleStatistics?
    /// Session Details source override (oMLX runs only). nil = default to the
    /// server's own metrics; once toggled it sticks. See BenchmarkView.
    @State private var detailsSourceOverride: Bool? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                // Header
                headerSection

                Divider()

                // Stats Grid
                statsSection

                // Charts
                if !samples.isEmpty {
                    chartsSection
                }

                // Prompt & Response
                promptResponseSection
            }
            .padding(Spacing.lg)
        }
        .task(id: session.id) {
            samples = await viewModel.loadSamples(for: session)
            statistics = try? await viewModel.databaseManager.queue.read { db in
                try BenchmarkSample.statistics(db: db, sessionId: session.id ?? 0)
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(session.modelName)
                    .font(.title2.bold())
                Spacer()
                StatusBadge(status: session.status)
            }

            HStack(spacing: Spacing.md) {
                Label(session.backend, systemImage: "point.3.connected.trianglepath.dotted")
                if let quant = session.modelQuantization {
                    Label(quant, systemImage: "slider.horizontal.3")
                }
                if let format = session.modelFormat {
                    Label(format, systemImage: format == "MLX" ? "cpu" : "doc.zipper")
                }
                Label(Formatters.dateTime(session.startedAt), systemImage: "calendar")
                if let duration = session.duration {
                    Label(Formatters.duration(duration), systemImage: "clock")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // oMLX runs carry the server's own metrics — let the user swap to
            // the verbatim server-reported figures (defaults to oMLX).
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
                    .labelsHidden()
                    .fixedSize()
                }
            }

            if showServerReportedDetails, let metrics = currentServerMetrics {
                serverReportedStatsGrid(metrics)
            } else {
                anubisStatsGrid
            }
        }
    }

    /// oMLX's reported `usage` block, parsed. nil for non-oMLX sessions.
    private var currentServerMetrics: [String: Any]? {
        guard let json = session.serverMetricsJSON,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private var hasServerReportedMetrics: Bool { currentServerMetrics != nil }

    private var showServerReportedDetails: Bool {
        detailsSourceOverride ?? hasServerReportedMetrics
    }

    /// Stats grid built straight from oMLX's reported usage — every value is
    /// the server's own number, not Anubis-derived.
    private func serverReportedStatsGrid(_ m: [String: Any]) -> some View {
        func dbl(_ key: String) -> Double? { (m[key] as? NSNumber)?.doubleValue }
        func intVal(_ key: String) -> Int? { (m[key] as? NSNumber)?.intValue }
        let cached = ((m["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? NSNumber)?.intValue

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: Spacing.md) {
            StatCell(title: "Prefill Tk/s", value: dbl("prompt_tokens_per_second").map { String(format: "%.2f tok/s", $0) } ?? "—")
            StatCell(title: "Generation Tk/s", value: dbl("generation_tokens_per_second").map { String(format: "%.2f tok/s", $0) } ?? "—")
            StatCell(title: "Time to First Token", value: dbl("time_to_first_token").map { String(format: "%.2fs", $0) } ?? "—")
            StatCell(title: "Total Time", value: dbl("total_time").map { String(format: "%.2fs", $0) } ?? "—")
            StatCell(title: "Prompt Eval", value: dbl("prompt_eval_duration").map { String(format: "%.2fs", $0) } ?? "—")
            StatCell(title: "Generation", value: dbl("generation_duration").map { String(format: "%.2fs", $0) } ?? "—")
            StatCell(title: "Model Load", value: dbl("model_load_duration").map { String(format: "%.2fs", $0) } ?? "—")
            StatCell(title: "Cached Tokens", value: cached.map { "\($0)" } ?? "—")
            StatCell(title: "Prompt Tokens", value: intVal("prompt_tokens").map { "\($0)" } ?? "—")
            StatCell(title: "Completion Tokens", value: intVal("completion_tokens").map { "\($0)" } ?? "—")
            StatCell(title: "Total Tokens", value: intVal("total_tokens").map { "\($0)" } ?? "—")
        }
    }

    private var anubisStatsGrid: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: Spacing.md) {
                // Row 1: Performance
                StatCell(
                    title: "Output Tk/s",
                    value: session.tokensPerSecond.map { Formatters.tokensPerSecond($0) } ?? "—"
                )
                .help(session.hasSuspiciousTiming
                      ? "This backend did not stream tokens incrementally — the measured generation duration is implausibly short for the token count, so tok/s reflects burst-decode time rather than real generation time. Try a backend that streams (Ollama, LM Studio with streaming enabled)."
                      : "")
                StatCell(
                    title: "Prefill Tk/s",
                    value: prefillTokensPerSecondString
                )
                StatCell(
                    title: "Time to First Token",
                    value: session.timeToFirstToken.map { Formatters.milliseconds($0 * 1000) } ?? "—"
                )
                StatCell(
                    title: "Avg Token Latency",
                    value: session.averageTokenLatencyMs.map { Formatters.milliseconds($0) } ?? "—"
                )

                // Optional reasoning row — only when the run produced thinking tokens
                if let rt = session.reasoningTokens, rt > 0,
                   let rd = session.reasoningDuration, rd > 0 {
                    StatCell(
                        title: "Reasoning Tk/s",
                        value: Formatters.tokensPerSecond(Double(rt) / rd)
                    )
                    StatCell(
                        title: "Reasoning Tokens",
                        value: "\(rt)"
                    )
                    StatCell(
                        title: "Reasoning Duration",
                        value: Formatters.duration(rd)
                    )
                    StatCell(
                        title: "Output Tokens (excl. reasoning)",
                        value: session.completionTokens.map { "\($0 - rt)" } ?? "—"
                    )
                }

                // Row 2: Token counts + Total Duration
                StatCell(
                    title: "Total Duration",
                    value: session.totalDuration.map { Formatters.duration($0) } ?? "—"
                )
                StatCell(
                    title: "Total Tokens",
                    value: session.totalTokens.map { "\($0)" } ?? "—"
                )
                StatCell(
                    title: "Completion Tokens",
                    value: session.completionTokens.map { "\($0)" } ?? "—"
                )
                StatCell(
                    title: "Context Length",
                    value: session.contextLength.map { "\($0)" } ?? "—"
                )

                // Row 3: Memory (Power & Freq follow below)
                StatCell(
                    title: "Peak Memory",
                    value: session.peakMemoryBytes.map { Formatters.bytes($0) } ?? "—"
                )

                // Row 3: Power & Frequency
                StatCell(
                    title: "Avg GPU Power",
                    value: session.avgGpuPowerWatts.map { Formatters.watts($0) } ?? "—"
                )
                StatCell(
                    title: "Avg System Power",
                    value: session.avgSystemPowerWatts.map { Formatters.watts($0) } ?? "—"
                )
                StatCell(
                    title: "Avg J/Token",
                    value: session.avgWattsPerToken.map { String(format: "%.2f J/tok", $0) } ?? "—"
                )
                StatCell(
                    title: "Avg GPU Freq",
                    value: session.avgGpuFrequencyMHz.map { String(format: "%.0f MHz", $0) } ?? "—"
                )

                // Row 4: Hardware (from sample statistics)
                if let stats = statistics {
                    StatCell(
                        title: "Avg GPU Util",
                        value: stats.avgGpuUtilization.map { Formatters.percentage($0) } ?? "—"
                    )
                    StatCell(
                        title: "Avg CPU Util",
                        value: stats.avgCpuUtilization.map { Formatters.percentage($0) } ?? "—"
                    )
                    StatCell(
                        title: "Peak GPU Power",
                        value: session.peakGpuPowerWatts.map { Formatters.watts($0) } ?? "—"
                    )
                    StatCell(
                        title: "Load Duration",
                        value: session.loadDuration.map { Formatters.duration($0) } ?? "—"
                    )
                }
            }

            // Chip info line
            if let chip = session.chipInfo {
                HStack(spacing: Spacing.sm) {
                    Text("Chip: \(chip.summary)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let backendName = session.backendProcessName {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                        Text("Backend: \(backendName)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.top, Spacing.xxs)
            }
        }
    }

    private var chartData: BenchmarkChartData {
        BenchmarkSample.chartData(from: samples)
    }

    /// Prefill (input) tokens per second = prompt tokens ÷ prompt eval duration.
    /// For Ollama, both are backend-reported. For OpenAI-compat/Apple, prompt
    /// eval duration is wall-clock TTFT and may include reasoning time on
    /// reasoning models (which we now track separately).
    private var prefillTokensPerSecondString: String {
        guard let promptTokens = session.promptTokens,
              let promptEval = session.promptEvalDuration,
              promptTokens > 0,
              promptEval > 0 else { return "—" }
        return Formatters.tokensPerSecond(Double(promptTokens) / promptEval)
    }

    private var chartsSection: some View {
        ChartGrid(
            data: chartData,
            hasHardwareMetrics: !chartData.gpuUtilization.isEmpty,
            hasPowerMetrics: chartData.hasPowerData,
            currentMemoryBytes: samples.last?.memoryUsedBytes ?? 0,
            totalMemoryBytes: samples.last?.memoryTotalBytes ?? 1,
            averageTps: session.tokensPerSecond,
            isComplete: true,
            // Per-core/GPU-core bars aren't persisted per run — hide them in
            // history rather than showing empty "Waiting for data…" cards.
            showCoreGrids: false
        )
    }

    private var promptResponseSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Prompt")
                    .font(.headline)
                Text(session.prompt)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: CornerRadius.md))
            }

            if let response = session.response {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Response")
                        .font(.headline)
                    Text(response)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: CornerRadius.md))
                }
            }
        }
    }
}

// MARK: - Stat Cell

struct StatCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.mono(16, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .metricCardStyle()
    }
}

// MARK: - Double Click Handler

/// NSViewRepresentable that detects double-clicks inside List rows
/// (SwiftUI gesture recognizers don't work reliably inside NSTableView-backed Lists)
private struct DoubleClickHandler: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = DoubleClickView(action: action)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private class DoubleClickView: NSView {
        let action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            if event.clickCount == 2 {
                action()
            }
        }
    }
}
