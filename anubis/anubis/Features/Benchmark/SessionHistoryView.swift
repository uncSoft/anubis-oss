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
    @State private var selectedSession: BenchmarkSession?
    @State private var showingClearConfirmation = false
    @State private var showingExportOptions = false
    @State private var exportedFileURL: URL?

    private var runningSessionCount: Int {
        viewModel.recentSessions.filter { $0.status == .running }.count
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

                    if let session = selectedSession {
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

            // Main content
            HSplitView {
                // Session List
                sessionList
                    .frame(minWidth: 320, idealWidth: 320, maxWidth: 450)

                // Session Detail
                if let session = selectedSession {
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
                        selectedSession = nil
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all \(viewModel.recentSessions.count) benchmark sessions and their data.")
            }
        .frame(minWidth: 600, minHeight: 400)
        .task {
            await viewModel.loadRecentSessions()
            if selectedSession == nil, let latest = viewModel.recentSessions.first {
                selectedSession = latest
            }
        }
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            List(viewModel.recentSessions, selection: $selectedSession) { session in
                SessionRow(session: session)
                    .tag(session)
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

                        Button(role: .destructive) {
                            Task {
                                await viewModel.deleteSession(session)
                                if selectedSession?.id == session.id {
                                    selectedSession = nil
                                }
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
            .listStyle(.inset)

            // Bottom status bar
            HStack {
                Text("\(viewModel.recentSessions.count) sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

                if let tps = session.tokensPerSecond {
                    Text(Formatters.tokensPerSecond(tps))
                        .font(.mono(11, weight: .medium))
                        .foregroundStyle(Color.chartTokens)
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
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: Spacing.md) {
                // Row 1: Performance
                StatCell(
                    title: "Tokens/sec",
                    value: session.tokensPerSecond.map { Formatters.tokensPerSecond($0) } ?? "—"
                )
                StatCell(
                    title: "Time to First Token",
                    value: session.timeToFirstToken.map { Formatters.milliseconds($0 * 1000) } ?? "—"
                )
                StatCell(
                    title: "Avg Token Latency",
                    value: session.averageTokenLatencyMs.map { Formatters.milliseconds($0) } ?? "—"
                )
                StatCell(
                    title: "Total Duration",
                    value: session.totalDuration.map { Formatters.duration($0) } ?? "—"
                )

                // Row 2: Token counts
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
                    title: "Avg W/Token",
                    value: session.avgWattsPerToken.map { String(format: "%.2f W/tok", $0) } ?? "—"
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

    private var chartsSection: some View {
        ChartGrid(
            data: chartData,
            hasHardwareMetrics: !chartData.gpuUtilization.isEmpty,
            hasPowerMetrics: chartData.hasPowerData,
            currentMemoryBytes: samples.last?.memoryUsedBytes ?? 0,
            totalMemoryBytes: samples.last?.memoryTotalBytes ?? 1
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
