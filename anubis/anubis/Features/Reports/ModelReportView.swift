//
//  ModelReportView.swift
//  anubis
//
//  Created on 2026-03-18.
//

import SwiftUI
import UniformTypeIdentifiers

struct ModelReportView: View {
    @StateObject private var viewModel: ModelReportViewModel

    init(databaseManager: DatabaseManager) {
        _viewModel = StateObject(wrappedValue: ModelReportViewModel(databaseManager: databaseManager))
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading {
                ProgressView("Loading benchmark data...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.allModels.isEmpty {
                emptyState
            } else {
                HSplitView {
                    modelSelector
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                    reportTable
                        .frame(minWidth: 500)
                }
            }
        }
        .navigationTitle("Reports")
        .task {
            await viewModel.loadModels()
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await viewModel.loadModels() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload benchmark data")

                Menu {
                    Button {
                        exportReport(asMarkdown: true)
                    } label: {
                        Label("Export as Markdown…", systemImage: "doc.text")
                    }
                    Button {
                        exportReport(asMarkdown: false)
                    } label: {
                        Label("Export as CSV…", systemImage: "tablecells")
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(viewModel.selectedModels.isEmpty)
                .help(viewModel.selectedModelIds.isEmpty
                      ? "Export all models in the report"
                      : "Export the \(viewModel.selectedModelIds.count) selected model\(viewModel.selectedModelIds.count == 1 ? "" : "s")")
            }
        }
    }

    // MARK: - Export

    private func exportReport(asMarkdown: Bool) {
        let rows = viewModel.selectedModels
        guard !rows.isEmpty else { return }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = dateFormatter.string(from: Date())

        let content: String
        let filename: String
        let contentType: UTType
        if asMarkdown {
            content = ExportService.exportModelReportToMarkdown(rows, chip: ChipInfo.current)
            filename = "anubis_report_\(stamp).md"
            contentType = .plainText
        } else {
            content = ExportService.exportModelReportToCSV(rows)
            filename = "anubis_report_\(stamp).csv"
            contentType = .commaSeparatedText
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                print("Failed to export report: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Spacing.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: CornerRadius.xl)
                    .fill(Color.emptyStateBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: CornerRadius.xl)
                            .strokeBorder(Color.cardBorder, lineWidth: 1)
                    }
                    .frame(width: 120, height: 100)
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
            }
            Text("No Benchmark Data")
                .font(.title2.weight(.semibold))
            Text("Run some benchmarks first, then come here to compare model performance across all your runs.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Model Selector (Left Panel)

    private var modelSelector: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Models")
                    .font(.headline)
                Spacer()
                if viewModel.selectedModelIds.isEmpty {
                    Button("Select All") { viewModel.selectAll() }
                        .font(.caption)
                        .buttonStyle(.borderless)
                } else {
                    Button("Clear (\(viewModel.selectedModelIds.count))") { viewModel.clearSelection() }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)

            Divider()

            // Hint
            if viewModel.selectedModelIds.isEmpty {
                Text("Showing all models. Select specific models to filter.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, Spacing.xs)
            }

            // Model list (alphabetical by name, then backend)
            List {
                ForEach(viewModel.allModels.sorted {
                    let cmp = $0.modelName.localizedCaseInsensitiveCompare($1.modelName)
                    return cmp == .orderedSame ? $0.backend < $1.backend : cmp == .orderedAscending
                }) { model in
                    modelSelectorRow(model)
                }
            }
            .listStyle(.sidebar)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func modelSelectorRow(_ model: ModelReportRow) -> some View {
        let isSelected = viewModel.selectedModelIds.contains(model.id)
        return Button {
            viewModel.toggleSelection(model.id)
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .font(.body)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.modelName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: Spacing.xxs) {
                        if let quant = model.quantization {
                            Text(quant)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let format = model.format {
                            Text(format.uppercased())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(model.backend)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Text("\(model.runCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help("\(model.runCount) completed runs")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Report Table (Right Panel)

    private var reportTable: some View {
        VStack(spacing: 0) {
            // Machine info banner
            machineInfoBanner

            Divider()

            // Table header
            reportTableHeader

            Divider()

            // Table rows
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.selectedModels.enumerated()), id: \.element.id) { index, model in
                        reportRow(model, isEven: index.isMultiple(of: 2))
                        Divider().opacity(0.5)
                    }
                }
            }

            Divider()

            // Summary footer
            if viewModel.selectedModels.count > 1 {
                summaryFooter
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var machineInfoBanner: some View {
        let chip = ChipInfo.current
        return HStack(spacing: Spacing.md) {
            Image(systemName: "desktopcomputer")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(chip.macModel ?? ChipInfo.macModelIdentifier)
                    .font(.headline)
                HStack(spacing: Spacing.xs) {
                    Text(chip.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(chip.performanceCores)P+\(chip.efficiencyCores)E · \(chip.gpuCores) GPU · \(chip.unifiedMemoryGB) GB")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("Anubis Performance Report")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var reportTableHeader: some View {
        HStack(spacing: Spacing.sm) {
            sortableHeaderCell("Model", column: .modelName, flexible: true, alignment: .leading)
            sortableHeaderCell("Avg Tk/s", column: .avgTokensPerSecond, width: 70)
            sortableHeaderCell("Avg W/Tk", column: .avgWattsPerToken, width: 70)
            sortableHeaderCell("TTFT", column: .avgTimeToFirstToken, width: 80)
            sortableHeaderCell("Avg Power", column: .avgSystemPowerWatts, width: 80)
            sortableHeaderCell("Peak Mem", column: .peakMemoryBytes, width: 80)
            sortableHeaderCell("Runs", column: .runCount, width: 40)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sortableHeaderCell(_ title: String, column: ReportSortColumn, width: CGFloat? = nil, flexible: Bool = false, alignment: Alignment = .trailing) -> some View {
        Button {
            viewModel.toggleSort(column)
        } label: {
            HStack(spacing: 2) {
                if alignment == .leading {
                    headerLabel(title, column: column)
                    Spacer()
                } else {
                    Spacer()
                    headerLabel(title, column: column)
                }
            }
            .frame(
                minWidth: flexible ? 160 : width,
                maxWidth: flexible ? .infinity : width,
                alignment: alignment
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func headerLabel(_ title: String, column: ReportSortColumn) -> some View {
        HStack(spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if viewModel.sortColumn == column {
                Image(systemName: viewModel.sortAscending ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func reportRow(_ model: ModelReportRow, isEven: Bool) -> some View {
        HStack(spacing: Spacing.sm) {
            // Model name + quant — left-aligned, flexible width
            VStack(alignment: .leading, spacing: 2) {
                Text(model.modelName)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(model.modelName)
                HStack(spacing: Spacing.xxs) {
                    if let quant = model.quantization {
                        Text(quant)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.15))
                            .cornerRadius(CornerRadius.sm)
                    }
                    if let format = model.format {
                        Text(format.uppercased())
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.15))
                            .cornerRadius(CornerRadius.sm)
                    }
                    Text(model.backend)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)

            // Tk/s
            Text(String(format: "%.1f", model.avgTokensPerSecond))
                .font(.mono(13, weight: .semibold))
                .frame(width: 70, alignment: .trailing)

            // W/Tk
            Text(model.avgWattsPerToken.map { String(format: "%.2f", $0) } ?? "—")
                .font(.mono(13))
                .foregroundStyle(model.avgWattsPerToken != nil ? .primary : .tertiary)
                .frame(width: 70, alignment: .trailing)

            // TTFT
            Text(model.avgTimeToFirstToken.map { String(format: "%.0f ms", $0 * 1000) } ?? "—")
                .font(.mono(13))
                .foregroundStyle(model.avgTimeToFirstToken != nil ? .primary : .tertiary)
                .frame(width: 80, alignment: .trailing)

            // Avg Power
            Text(model.avgSystemPowerWatts.map { String(format: "%.1f W", $0) } ?? "—")
                .font(.mono(13))
                .foregroundStyle(model.avgSystemPowerWatts != nil ? .primary : .tertiary)
                .frame(width: 80, alignment: .trailing)

            // Peak Memory
            Text(model.peakMemoryBytes.map { formatBytes($0) } ?? "—")
                .font(.mono(13))
                .foregroundStyle(model.peakMemoryBytes != nil ? .primary : .tertiary)
                .frame(width: 80, alignment: .trailing)

            // Runs
            Text("\(model.runCount)")
                .font(.mono(13))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(isEven ? Color.clear : Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    private var summaryFooter: some View {
        let models = viewModel.selectedModels
        let best = models.max(by: { $0.avgTokensPerSecond < $1.avgTokensPerSecond })
        let mostEfficient = models.filter { $0.avgWattsPerToken != nil }.min(by: { $0.avgWattsPerToken! < $1.avgWattsPerToken! })

        return HStack(spacing: Spacing.lg) {
            if let best = best {
                Label {
                    Text("Fastest: **\(best.modelName)** (\(String(format: "%.1f", best.avgTokensPerSecond)) tk/s)")
                        .font(.caption)
                } icon: {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.yellow)
                }
            }
            if let eff = mostEfficient {
                Label {
                    Text("Most efficient: **\(eff.modelName)** (\(String(format: "%.2f", eff.avgWattsPerToken!)) W/tk)")
                        .font(.caption)
                } icon: {
                    Image(systemName: "leaf.fill")
                        .foregroundStyle(.green)
                }
            }
            Spacer()
            Text("\(models.count) models · \(models.reduce(0) { $0 + $1.runCount }) total runs")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }
}
