//
//  FlowReportView.swift
//  anubis
//
//  Post-run report for a FlowRun. Intentionally designed to be
//  "video-ready": a creator should be able to render this card to a
//  PNG and drop it straight into a YouTube thumbnail, slide deck, or
//  social post.
//
//  Three layers:
//    1. FlowReportView         — top-level container, scrollable
//                                preview + export bar.
//    2. FlowReportCard16x9     — the renderable card (1920×1080 frame
//                                at export time, scales down for
//                                on-screen preview).
//    3. Card sub-views         — hero, leaderboard, methodology
//                                footer. Always render in a forced
//                                dark theme so the exported asset
//                                looks the same on every machine.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FlowReportView: View {
    let data: FlowReportData
    let onClose: (() -> Void)?

    /// Active card aspect for the on-screen preview. Each value also
    /// drives which renderer is used for Copy Image and Save PNG.
    @State private var aspect: ReportAspect = .landscape16x9

    init(data: FlowReportData, onClose: (() -> Void)? = nil) {
        self.data = data
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            aspectToggle
            Divider()

            // Aspect-fit whichever card variant is selected. The
            // FixedAspectScaler ensures the design-time canvas (1920x1080
            // or 1080x1080) renders pixel-correct then scales to fit
            // the sheet without clipping or overflow.
            Group {
                switch aspect {
                case .landscape16x9:
                    FixedAspectScaler(designWidth: 1920, designHeight: 1080) {
                        FlowReportCard16x9(data: data)
                    }
                case .square1x1:
                    FixedAspectScaler(designWidth: 1080, designHeight: 1080) {
                        FlowReportCard1x1(data: data)
                    }
                }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.85))

            Divider()
            exportBar
        }
    }

    /// Two-button segmented toggle pinned above the preview. Reading
    /// "16:9 / 1:1" so users immediately know which export each
    /// button will produce.
    private var aspectToggle: some View {
        HStack(spacing: Spacing.md) {
            Picker("Aspect", selection: $aspect) {
                ForEach(ReportAspect.allCases) { a in
                    Text(a.label).tag(a)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            Spacer()
            Text("Card: \(aspect.canvasLabel)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "chart.bar.doc.horizontal")
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text("Flow Report").font(.headline)
                Text(data.flowRun.flowNameSnapshot)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let onClose = onClose {
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Spacing.md)
    }

    // MARK: - Export bar

    private var exportBar: some View {
        HStack(spacing: Spacing.sm) {
            Button {
                copyImageToClipboard()
            } label: {
                Label("Copy Image", systemImage: "doc.on.clipboard")
            }
            Button {
                saveImage()
            } label: {
                Label("Save PNG (\(aspect.label))", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            Button {
                saveCSV()
            } label: {
                Label("Save CSV", systemImage: "tablecells")
            }
            Spacer()
            Text("\(aspect.canvasLabel) · 2× retina")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.md)
    }

    // MARK: - Export

    @MainActor
    private func renderImage() -> NSImage? {
        let size = aspect.designSize
        let content: AnyView = {
            switch aspect {
            case .landscape16x9:
                return AnyView(FlowReportCard16x9(data: data)
                    .frame(width: size.width, height: size.height))
            case .square1x1:
                return AnyView(FlowReportCard1x1(data: data)
                    .frame(width: size.width, height: size.height))
            }
        }()
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2.0
        renderer.proposedSize = .init(width: size.width, height: size.height)
        return renderer.nsImage
    }

    private func copyImageToClipboard() {
        guard let image = renderImage() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    private func saveImage() {
        guard let image = renderImage(),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(filenameSlug).png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? pngData.write(to: url)
    }

    private func saveCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(filenameSlug).csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.toCSV().write(to: url, atomically: true, encoding: .utf8)
    }

    private var filenameSlug: String {
        let nameSlug = data.flowRun.flowNameSnapshot
            .lowercased()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "_")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let datePart = formatter.string(from: data.flowRun.startedAt)
        return "anubis-report-\(nameSlug)-\(datePart)-\(aspect.filenameTag)"
    }
}

// MARK: - Aspect

enum ReportAspect: String, CaseIterable, Identifiable {
    case landscape16x9 = "16:9"
    case square1x1 = "1:1"

    var id: String { rawValue }
    var label: String { rawValue }

    var designSize: CGSize {
        switch self {
        case .landscape16x9: return CGSize(width: 1920, height: 1080)
        case .square1x1:     return CGSize(width: 1080, height: 1080)
        }
    }

    var canvasLabel: String {
        switch self {
        case .landscape16x9: return "1920 × 1080"
        case .square1x1:     return "1080 × 1080"
        }
    }

    var filenameTag: String {
        switch self {
        case .landscape16x9: return "16x9"
        case .square1x1:     return "1x1"
        }
    }
}

// MARK: - The renderable card

/// 1920×1080 card. Hero (top), leaderboard (middle), methodology +
/// brand footer (bottom). Forced dark theme so the export looks the
/// same whether the user runs the app in light or dark mode.
struct FlowReportCard16x9: View {
    let data: FlowReportData

    var body: some View {
        ZStack {
            // Background — subtle gradient so a flat dark fill doesn't
            // bake into video compression as a single block.
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.09, blue: 0.12),
                         Color(red: 0.04, green: 0.05, blue: 0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(alignment: .leading, spacing: 0) {
                hero
                    .padding(.horizontal, 64)
                    .padding(.top, 44)
                    .padding(.bottom, 28)
                Divider().background(Color.white.opacity(0.10))
                leaderboard
                    .padding(.horizontal, 64)
                    .padding(.vertical, 28)
                Spacer(minLength: 0)
                Divider().background(Color.white.opacity(0.10))
                methodology
                    .padding(.horizontal, 64)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
            }
        }
        .frame(width: 1920, height: 1080)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "eye.trianglebadge.exclamationmark")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text("ANUBIS")
                        .font(.system(size: 22, weight: .black))
                        .tracking(4)
                    Text("LLM BENCHMARK REPORT")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .tracking(2)
                }

                Text(data.flowRun.flowNameSnapshot)
                    .font(.system(size: 52, weight: .heavy))
                    .lineLimit(2)

                heroSummaryRow
                    .padding(.top, 4)
            }

            Spacer(minLength: 0)

            // Right-hand winner callout — the headline number Alex
            // would screenshot.
            if let winner = data.winner {
                winnerCallout(winner)
            }
        }
    }

    private var heroSummaryRow: some View {
        HStack(spacing: 18) {
            heroPill(value: "\(data.completedSessionCount) runs",
                     label: "completed",
                     icon: "play.fill")
            heroPill(value: "\(data.modelRows.count) model\(data.modelRows.count == 1 ? "" : "s")",
                     label: modelPillLabel,
                     icon: "cube.box")
            if let duration = data.duration {
                heroPill(value: formatDuration(duration),
                         label: "wall clock",
                         icon: "clock")
            }
            if data.failedSessionCount > 0 {
                heroPill(value: "\(data.failedSessionCount)",
                         label: "failed",
                         icon: "exclamationmark.triangle",
                         tint: Color.red.opacity(0.8))
            }
        }
        .padding(.top, 8)
    }

    /// Reads "tested" when there's only one model (nothing to compare
    /// to), "compared" when there are multiple. Mirrors what the rows
    /// actually represent so the header line isn't misleading.
    private var modelPillLabel: String {
        data.modelRows.count <= 1 ? "tested" : "compared"
    }

    private func heroPill(value: String, label: String, icon: String, tint: Color = .white.opacity(0.85)) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func winnerCallout(_ winner: FlowReportData.PerModelRow) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 8) {
                Text("🥇")
                    .font(.system(size: 16))
                Text("WINNER")
                    .font(.system(size: 14, weight: .black))
                    .tracking(3)
                    .foregroundStyle(Color.yellow.opacity(0.9))
            }
            Text(winner.modelName)
                .font(.system(size: 22, weight: .bold))
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatTPS(winner.meanTPS))
                    .font(.system(size: 60, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 0) {
                    Text("tokens").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    Text("per second").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                }
            }
            if let lo = winner.ciLowTPS, let hi = winner.ciHighTPS {
                Text(String(format: "95%% CI %.1f – %.1f · n=%d", lo, hi, winner.n))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(width: 480, alignment: .trailing)
    }

    // MARK: Leaderboard

    @ViewBuilder
    private var leaderboard: some View {
        let rows = data.modelRows
        if rows.count == 1 {
            // Single-model spotlight: fills horizontal width and rises
            // taller so the export doesn't have a half-empty card with
            // dead space below. Per-rep mini-bars carry the extra
            // height naturally.
            if let only = rows.first {
                SpotlightModelCard(row: only)
            }
        } else {
            let columns = leaderboardColumns(for: rows.count)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(rows) { row in
                    ModelCard(row: row, maxTPS: rows.first?.meanTPS ?? 0)
                }
            }
        }
    }

    /// Pick column count based on how many model rows we have. 1×N
    /// for 1-2 models gives big cards; 2×N for 3-4; 3×N for 5+.
    private func leaderboardColumns(for count: Int) -> [GridItem] {
        let n: Int
        switch count {
        case 0...2: n = max(1, count)
        case 3...4: n = 2
        default:    n = 3
        }
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: n)
    }

    // MARK: Methodology

    private var methodology: some View {
        HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 8) {
                Text("METHODOLOGY")
                    .font(.system(size: 12, weight: .black))
                    .tracking(3)
                    .foregroundStyle(.white.opacity(0.4))
                Text(methodologyLine)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                if let chip = data.chipInfo {
                    Text(chipSummary(chip))
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "eye.trianglebadge.exclamationmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange.opacity(0.85))
                    Text("Generated by Anubis OSS")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Text("github.com/uncsoft/anubis-oss")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                Text(data.flowRun.startedAt.formatted(date: .long, time: .shortened))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private var methodologyLine: String {
        // Best-effort summary — pull the first Set Parameters / first
        // Set Prompt from the snapshot if available, else fall back to
        // session-derived hints.
        let prompts = Set(data.allSessions.map { $0.prompt }).sorted()
        let promptHint: String
        if prompts.count == 1, let p = prompts.first {
            promptHint = "Prompt: \(truncated(p, max: 100))"
        } else if prompts.count > 1 {
            promptHint = "Prompts: \(prompts.count) variants"
        } else {
            promptHint = "Prompt: (unknown)"
        }
        return promptHint
    }

    private func chipSummary(_ chip: ChipInfo) -> String {
        var parts: [String] = [chip.name]
        parts.append("\(chip.coreCount)C CPU")
        parts.append("\(chip.gpuCores)C GPU")
        parts.append("\(chip.unifiedMemoryGB)GB")
        if let model = chip.macModel { parts.append(model) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Per-model card

private struct ModelCard: View {
    let row: FlowReportData.PerModelRow
    /// Used to size the relative tok/s bar.
    let maxTPS: Double

    private var medal: String? {
        switch row.rank {
        case 1: return "🥇"
        case 2: return "🥈"
        case 3: return "🥉"
        default: return nil
        }
    }

    private var rankBadgeBackground: Color {
        switch row.rank {
        case 1: return Color.yellow.opacity(0.18)
        case 2: return Color.gray.opacity(0.22)
        case 3: return Color(red: 0.7, green: 0.4, blue: 0.2).opacity(0.18)
        default: return Color.white.opacity(0.06)
        }
    }

    private var barFraction: CGFloat {
        guard maxTPS > 0 else { return 0 }
        return CGFloat(min(1.0, row.meanTPS / maxTPS))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: rank badge + model name + backend
            HStack(spacing: 10) {
                if let medal = medal {
                    Text(medal).font(.system(size: 26))
                } else {
                    Text("#\(row.rank)")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(rankBadgeBackground, in: Capsule())
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.modelName)
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(1)
                    Text("\(row.backend) · \(row.n) rep\(row.n == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
            }

            // Big tok/s + CI
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formatTPS(row.meanTPS))
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .monospacedDigit()
                Text("tok/s")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.leading, 4)
                Spacer()
            }
            if let lo = row.ciLowTPS, let hi = row.ciHighTPS, row.n > 1 {
                Text(String(format: "± %.1f  ·  95%% CI %.1f – %.1f", row.stdevTPS, lo, hi))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            } else if row.n == 1 {
                Text("single rep (no CI)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }

            // Relative bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color.orange, Color.orange.opacity(0.6)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: geo.size.width * barFraction)
                }
            }
            .frame(height: 8)

            // Footer stats — TTFT, total tokens, avg duration
            HStack(spacing: 20) {
                statBlock(label: "TTFT",
                          value: row.meanTTFT.map { String(format: "%.0fms", $0 * 1000) } ?? "—")
                statBlock(label: "Tokens",
                          value: row.meanTotalTokens.map { String(format: "%.0f", $0) } ?? "—")
                statBlock(label: "Duration",
                          value: row.meanTotalDuration.map { String(format: "%.1fs", $0) } ?? "—")
                Spacer()
            }

            // Per-rep details, compact form. The same idea as the
            // spotlight table but width-constrained so it fits in a
            // 2- or 3-column grid cell.
            if row.n > 1 {
                Divider().background(Color.white.opacity(0.10))
                compactPerRepTable
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func statBlock(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .tracking(1)
        }
    }

    /// Per-rep mini-table for the grid layout. Drops the bar column
    /// so it stays readable in a narrower cell; shows rep number,
    /// tok/s, TTFT for every individual session.
    private var compactPerRepTable: some View {
        let sessions = row.completedSessions
        return VStack(alignment: .leading, spacing: 4) {
            Text("PER-REP")
                .font(.system(size: 9, weight: .black))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.4))
            HStack(spacing: 10) {
                Text("REP")
                    .font(.system(size: 8, weight: .black))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(width: 28, alignment: .leading)
                Text("TOK/S")
                    .font(.system(size: 8, weight: .black))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(width: 56, alignment: .leading)
                Spacer(minLength: 0)
                Text("TTFT")
                    .font(.system(size: 8, weight: .black))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(width: 70, alignment: .trailing)
                Text("TOK")
                    .font(.system(size: 8, weight: .black))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(width: 50, alignment: .trailing)
            }
            ForEach(Array(sessions.enumerated()), id: \.offset) { idx, s in
                HStack(spacing: 10) {
                    Text("\(idx + 1)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 28, alignment: .leading)
                    Text(formatTPS(s.tokensPerSecond ?? 0))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .frame(width: 56, alignment: .leading)
                    Spacer(minLength: 0)
                    Text(s.timeToFirstToken.map { String(format: "%.0fms", $0 * 1000) } ?? "—")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 70, alignment: .trailing)
                    Text(s.totalTokens.map { "\($0)" } ?? "—")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 50, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Spotlight (single-model) card

/// Used by the leaderboard when there is exactly one model in the
/// report. Full-width, much bigger headline numbers, and a per-rep
/// mini-bar strip so the export's bottom half doesn't read as empty.
private struct SpotlightModelCard: View {
    let row: FlowReportData.PerModelRow

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Text("🥇").font(.system(size: 36))
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.modelName)
                        .font(.system(size: 30, weight: .bold))
                        .lineLimit(1)
                    Text("\(row.backend) · \(row.n) rep\(row.n == 1 ? "" : "s")\(row.attemptCount != row.n ? " · \(row.attemptCount - row.n) failed" : "")")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
            }

            // Big numbers, multi-column.
            HStack(alignment: .firstTextBaseline, spacing: 48) {
                spotlightNumber(
                    value: formatTPS(row.meanTPS),
                    unit: "tok/s",
                    sub: ciLine
                )
                if let ttft = row.meanTTFT {
                    spotlightNumber(
                        value: String(format: "%.0f", ttft * 1000),
                        unit: "ms TTFT",
                        sub: "time to first token"
                    )
                }
                if let tokens = row.meanTotalTokens {
                    spotlightNumber(
                        value: String(format: "%.0f", tokens),
                        unit: "tokens",
                        sub: "average per rep"
                    )
                }
                if let dur = row.meanTotalDuration {
                    spotlightNumber(
                        value: String(format: "%.1fs", dur),
                        unit: "duration",
                        sub: "average per rep"
                    )
                }
                Spacer()
            }

            // Per-rep results table — every individual run's numbers,
            // not just the aggregate. Tabular so a viewer can verify
            // the mean and spot outlier reps. Suppressed for n=1.
            if row.n > 1 {
                perRepTable
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var ciLine: String {
        if let lo = row.ciLowTPS, let hi = row.ciHighTPS, row.n > 1 {
            return String(format: "± %.1f · 95%% CI %.1f – %.1f", row.stdevTPS, lo, hi)
        }
        return "single rep (no CI)"
    }

    private func spotlightNumber(value: String, unit: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 72, weight: .black, design: .rounded))
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Text(sub)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    /// Per-rep results table for the spotlight. Each row is one
    /// individual BenchmarkSession; columns are the raw measurements
    /// for that rep. The orange bar in the tok/s column is sized
    /// relative to the fastest rep in this model so outliers pop
    /// visually as well as numerically.
    private var perRepTable: some View {
        let sessions = row.completedSessions
        let maxTPS = max(sessions.compactMap { $0.tokensPerSecond }.max() ?? 1, 0.001)

        return VStack(alignment: .leading, spacing: 8) {
            Text("PER-REP RESULTS")
                .font(.system(size: 11, weight: .black))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.4))

            // Header row.
            HStack(spacing: 12) {
                tableColHeader("Rep", width: 44)
                tableColHeader("tok/s", width: 64)
                Spacer(minLength: 0)         // bar column expands
                tableColHeader("TTFT", width: 80, alignment: .trailing)
                tableColHeader("Tokens", width: 70, alignment: .trailing)
                tableColHeader("Duration", width: 80, alignment: .trailing)
            }

            // Data rows.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(sessions.enumerated()), id: \.offset) { idx, s in
                    HStack(spacing: 12) {
                        Text("\(idx + 1)")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 44, alignment: .leading)
                        Text(formatTPS(s.tokensPerSecond ?? 0))
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .frame(width: 64, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.06))
                                Capsule()
                                    .fill(LinearGradient(
                                        colors: [Color.orange, Color.orange.opacity(0.55)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ))
                                    .frame(width: geo.size.width * CGFloat((s.tokensPerSecond ?? 0) / maxTPS))
                            }
                        }
                        .frame(height: 10)
                        Text(s.timeToFirstToken.map { String(format: "%.0fms", $0 * 1000) } ?? "—")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 80, alignment: .trailing)
                        Text(s.totalTokens.map { "\($0)" } ?? "—")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 70, alignment: .trailing)
                        Text(s.totalDuration.map { String(format: "%.1fs", $0) } ?? "—")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 80, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func tableColHeader(_ text: String, width: CGFloat, alignment: Alignment = .leading) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .black))
            .tracking(1.5)
            .foregroundStyle(.white.opacity(0.4))
            .frame(width: width, alignment: alignment)
    }
}

// MARK: - 1:1 square card (Instagram / X friendly)

/// 1080×1080 variant optimised for social-square aspect. Stacked
/// hero → leaderboard list → methodology footer. Up to 4 models
/// shown as full-width strip cards; if there are more, the rest
/// are summarised on the last strip ("+ N more — see CSV").
struct FlowReportCard1x1: View {
    let data: FlowReportData

    /// Tighter cap than 16:9 since vertical space is the bottleneck.
    private let maxModelCards = 4

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.09, blue: 0.12),
                         Color(red: 0.04, green: 0.05, blue: 0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(alignment: .leading, spacing: 0) {
                hero
                    .padding(.horizontal, 56)
                    .padding(.top, 44)
                    .padding(.bottom, 22)

                Divider().background(Color.white.opacity(0.10))

                leaderboard
                    .padding(.horizontal, 56)
                    .padding(.vertical, 22)

                Spacer(minLength: 0)

                Divider().background(Color.white.opacity(0.10))
                methodology
                    .padding(.horizontal, 56)
                    .padding(.top, 18)
                    .padding(.bottom, 30)
            }
        }
        .frame(width: 1080, height: 1080)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("ANUBIS")
                    .font(.system(size: 18, weight: .black))
                    .tracking(3)
                Text("BENCHMARK REPORT")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .tracking(2)
                Spacer()
            }

            Text(data.flowRun.flowNameSnapshot)
                .font(.system(size: 42, weight: .heavy))
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            // Pill row — same content as 16:9 but smaller.
            HStack(spacing: 12) {
                heroPill(value: "\(data.completedSessionCount) runs",
                         icon: "play.fill")
                heroPill(value: "\(data.modelRows.count) model\(data.modelRows.count == 1 ? "" : "s")",
                         icon: "cube.box")
                if let duration = data.duration {
                    heroPill(value: formatDuration(duration), icon: "clock")
                }
                if data.failedSessionCount > 0 {
                    heroPill(value: "\(data.failedSessionCount) failed",
                             icon: "exclamationmark.triangle",
                             tint: Color.red.opacity(0.85))
                }
                Spacer()
            }
            .padding(.top, 4)

            // Inline winner callout (one row, big number) so the
            // square layout still leads with the key result.
            if let winner = data.winner {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("🥇")
                        .font(.system(size: 22))
                    Text(winner.modelName)
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(1)
                    Spacer()
                    Text(formatTPS(winner.meanTPS))
                        .font(.system(size: 36, weight: .black, design: .rounded))
                        .monospacedDigit()
                    Text("tok/s")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.top, 6)
                if let lo = winner.ciLowTPS, let hi = winner.ciHighTPS {
                    Text(String(format: "95%% CI %.1f – %.1f · n=%d", lo, hi, winner.n))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
    }

    private func heroPill(value: String, icon: String, tint: Color = .white.opacity(0.85)) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
    }

    // MARK: Leaderboard

    private var leaderboard: some View {
        let rows = data.modelRows
        let visible = Array(rows.prefix(maxModelCards))
        let overflow = rows.count - visible.count

        return VStack(alignment: .leading, spacing: 10) {
            ForEach(visible) { row in
                SquareModelStrip(row: row, maxTPS: rows.first?.meanTPS ?? 0)
            }
            if overflow > 0 {
                Text("+ \(overflow) more model\(overflow == 1 ? "" : "s") — see full CSV")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 4)
            }
        }
    }

    // MARK: Methodology

    private var methodology: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("METHODOLOGY")
                        .font(.system(size: 11, weight: .black))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.4))
                    Text(methodologyLine)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                    if let chip = data.chipInfo {
                        Text(chipSummary(chip))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "eye.trianglebadge.exclamationmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange.opacity(0.85))
                        Text("Anubis OSS")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Text("github.com/uncsoft/anubis-oss")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                    Text(data.flowRun.startedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }

    private var methodologyLine: String {
        let prompts = Set(data.allSessions.map { $0.prompt }).sorted()
        if prompts.count == 1, let p = prompts.first {
            return "Prompt: \(truncated(p, max: 90))"
        } else if prompts.count > 1 {
            return "Prompts: \(prompts.count) variants"
        }
        return "Prompt: (unknown)"
    }

    private func chipSummary(_ chip: ChipInfo) -> String {
        var parts: [String] = [chip.name]
        parts.append("\(chip.coreCount)C CPU")
        parts.append("\(chip.gpuCores)C GPU")
        parts.append("\(chip.unifiedMemoryGB)GB")
        return parts.joined(separator: " · ")
    }
}

/// Wide one-line strip for each model in the 1:1 layout. Single
/// horizontal row carrying rank, name, tok/s, CI line, and a
/// relative bar — built to be scannable, not to compete with the
/// 16:9 cards' depth.
private struct SquareModelStrip: View {
    let row: FlowReportData.PerModelRow
    let maxTPS: Double

    private var medal: String? {
        switch row.rank {
        case 1: return "🥇"
        case 2: return "🥈"
        case 3: return "🥉"
        default: return nil
        }
    }

    private var barFraction: CGFloat {
        guard maxTPS > 0 else { return 0 }
        return CGFloat(min(1.0, row.meanTPS / maxTPS))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let medal = medal {
                    Text(medal).font(.system(size: 20))
                } else {
                    Text("#\(row.rank)")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                Text(row.modelName)
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(1)
                Spacer()
                Text(formatTPS(row.meanTPS))
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .monospacedDigit()
                Text("tok/s")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }

            // Compact secondary metrics line — TTFT + tokens + reps.
            HStack(spacing: 12) {
                if let ttft = row.meanTTFT {
                    Text(String(format: "TTFT %.0fms", ttft * 1000))
                }
                if let tokens = row.meanTotalTokens {
                    Text(String(format: "%.0f tok", tokens))
                }
                Text("n=\(row.n)")
                if let lo = row.ciLowTPS, let hi = row.ciHighTPS, row.n > 1 {
                    Text(String(format: "CI %.1f – %.1f", lo, hi))
                }
                Spacer()
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.6))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color.orange, Color.orange.opacity(0.6)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: geo.size.width * barFraction)
                }
            }
            .frame(height: 6)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

// MARK: - Aspect-fit scaler for preview

/// Renders `content` at its design size, then scales it down to fit
/// whatever bounds the parent gives us — preserving aspect ratio.
/// Use for previewing fixed-canvas designs (like the 1920x1080 report
/// card) inside an arbitrary window without scrollbars or clipping.
private struct FixedAspectScaler<Content: View>: View {
    let designWidth: CGFloat
    let designHeight: CGFloat
    let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let scale = min(
                proxy.size.width / designWidth,
                proxy.size.height / designHeight
            )
            content()
                .frame(width: designWidth, height: designHeight)
                .scaleEffect(scale, anchor: .center)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(designWidth / designHeight, contentMode: .fit)
    }
}

// MARK: - Shared helpers

private func formatTPS(_ value: Double) -> String {
    String(format: value >= 100 ? "%.0f" : "%.1f", value)
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

private func truncated(_ s: String, max: Int) -> String {
    if s.count <= max { return s }
    let end = s.index(s.startIndex, offsetBy: max)
    return s[..<end] + "…"
}
