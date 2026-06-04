//
//  FlowRunView.swift
//  anubis
//
//  Modal sheet that drives a FlowExecutor and renders live progress.
//  Layout (top to bottom):
//    - Header with flow name, status pill, elapsed clock
//    - Two-column body: step tree (left) + scrollback log (right)
//    - Footer with the latest session preview + Stop / Close
//
//  The executor is held by the parent so this view is purely a
//  consumer of @Published state. Stop -> Task.cancel on the
//  executor's root task; the view itself never holds inference
//  state directly.
//

import SwiftUI
import AppKit
@preconcurrency import GRDB

struct FlowRunView: View {
    @ObservedObject var executor: FlowExecutor
    let flow: Flow
    let databaseManager: DatabaseManager
    let onClose: () -> Void

    /// Wall-clock elapsed time, ticked once a second while running.
    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                stepTree
                    .frame(minWidth: 320, idealWidth: 380)
                logPane
                    .frame(minWidth: 320, idealWidth: 420)
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 440)
        .onAppear { startTimerIfNeeded() }
        .onDisappear { stopTimer() }
        .onChange(of: executor.state) { _, _ in
            // Stop the elapsed clock as soon as the executor leaves
            // .running so the final value stays pinned.
            if executor.state != .running {
                stopTimer()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "play.fill")
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(flow.name).font(.headline)
                HStack(spacing: 6) {
                    statePill
                    Text(elapsedText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if executor.totalExpectedRuns > 0 {
                        Text("·").foregroundStyle(.secondary)
                        Text(runProgressText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text("·").foregroundStyle(.secondary)
                    Text("\(executor.completedSessionCount) done").font(.caption).foregroundStyle(.secondary)
                    if executor.failedSessionCount > 0 {
                        Text("·").foregroundStyle(.secondary)
                        Text("\(executor.failedSessionCount) failed").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Spacer()
            if executor.totalExpectedRuns > 0 {
                runProgressBar
            }
        }
        .padding(Spacing.md)
    }

    private var statePill: some View {
        HStack(spacing: 4) {
            switch executor.state {
            case .idle:
                Image(systemName: "circle").foregroundStyle(.secondary)
                Text("Idle").foregroundStyle(.secondary)
            case .running:
                ProgressView().controlSize(.mini)
                Text("Running").foregroundStyle(.blue)
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Completed").foregroundStyle(.green)
            case .failed(let msg):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text("Failed").foregroundStyle(.red).help(msg)
            case .cancelled:
                Image(systemName: "stop.fill").foregroundStyle(.orange)
                Text("Cancelled").foregroundStyle(.orange)
            }
        }
        .font(.caption.weight(.semibold))
    }

    private var elapsedText: String {
        let totalSeconds = Int(elapsed)
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    /// "Run 4 of 30" style counter. Clamps so the header doesn't read
    /// "5 of 4" if the executor over-counts (e.g. a failed run mid-rep).
    private var runProgressText: String {
        let total = executor.totalExpectedRuns
        let current = min(executor.attemptedRunCount, total)
        return "Run \(current) of \(total)"
    }

    /// Slim progress bar mirroring runProgressText, pinned to the
    /// header's trailing edge.
    private var runProgressBar: some View {
        let total = max(1, executor.totalExpectedRuns)
        let done = min(executor.completedSessionCount, total)
        return VStack(alignment: .trailing, spacing: 2) {
            ProgressView(value: Double(done), total: Double(total))
                .progressViewStyle(.linear)
                .frame(width: 140)
            Text("\(done) / \(total) complete")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Step tree

    private var stepTree: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                FlowRunStepLevel(steps: flow.steps, executor: executor, depth: 0)
            }
            .padding(Spacing.md)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Log pane

    private var logPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(executor.log) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Image(systemName: entry.level.icon)
                                .foregroundStyle(entry.level.color)
                                .font(.system(size: 10))
                                .frame(width: 14)
                            Text(entry.message)
                                .font(.system(size: 11))
                                .foregroundStyle(entry.level.color)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .id(entry.id)
                    }
                }
                .padding(Spacing.md)
            }
            .background(Color(NSColor.textBackgroundColor))
            .onChange(of: executor.log.count) { _, _ in
                // Auto-scroll to newest. The id-based scroll
                // sidesteps the bounce some users see with .bottom.
                if let last = executor.log.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let session = executor.latestSession {
                latestSessionRow(session)
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, Spacing.sm)
            }

            HStack {
                Spacer()
                if executor.state == .running {
                    Button {
                        executor.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .keyboardShortcut(".", modifiers: .command)
                    .tint(.red)
                } else {
                    if executor.completedSessionCount > 0 {
                        Button {
                            openReport()
                        } label: {
                            Label("View Report", systemImage: "chart.bar.doc.horizontal")
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                    }
                    Button("Close") { onClose() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(Spacing.md)
        }
    }

    /// Fetch the just-completed sessions from the DB and present the
    /// report sheet. Read happens off the main thread (GRDB queue is
    /// fine to use from MainActor — internally serialized).
    private func openReport() {
        guard let run = executor.flowRun else { return }
        do {
            let sessions = try databaseManager.queue.read { db in
                try run.sessions(db: db)
            }
            FlowReportWindowController.shared.present(
                data: FlowReportData.compute(flowRun: run, sessions: sessions)
            )
        } catch {
            // Surfacing this in the log is enough — the only realistic
            // failure mode is a deleted DB, which the user notices fast.
            print("Failed to fetch flow report data: \(error)")
        }
    }

    private func latestSessionRow(_ session: BenchmarkSession) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Latest: \(session.modelName)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let tps = session.tokensPerSecond {
                        statChip("tok/s", String(format: "%.1f", tps))
                    }
                    if let ttft = session.timeToFirstToken {
                        statChip("TTFT", String(format: "%.0fms", ttft * 1000))
                    }
                    if let total = session.totalTokens {
                        statChip("tokens", "\(total)")
                    }
                }
            }
            Spacer()
        }
        .padding(Spacing.sm)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: CornerRadius.sm))
    }

    private func statChip(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced))
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    // MARK: - Timer

    private func startTimerIfNeeded() {
        guard timer == nil, executor.state == .running else { return }
        let startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Step tree row (recursive)

private struct FlowRunStepLevel: View {
    let steps: [FlowStep]
    @ObservedObject var executor: FlowExecutor
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(steps) { step in
                FlowRunStepRow(step: step, executor: executor)
                if step.kind.isContainer, let children = step.kind.children, !children.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        FlowRunStepLevel(steps: children, executor: executor, depth: depth + 1)
                    }
                    .padding(.leading, Spacing.lg)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.25))
                            .frame(width: 2)
                            .padding(.leading, Spacing.xs)
                    }
                }
            }
        }
    }
}

private struct FlowRunStepRow: View {
    let step: FlowStep
    @ObservedObject var executor: FlowExecutor

    private var progress: FlowExecutor.StepProgress? {
        executor.progress[step.id]
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            statusIcon
                .frame(width: 18, height: 18)
            Image(systemName: step.kind.iconName)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.kind.displayName)
                    .font(.system(size: 12, weight: .medium))
                if let detail = progress?.detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if case .failed(let msg) = progress?.status {
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let p = progress, let ended = p.endedAt, let started = p.startedAt {
                let dur = ended.timeIntervalSince(started)
                Text(String(format: "%.1fs", dur))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 4)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch progress?.status ?? .pending {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.mini)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var rowBackground: Color {
        switch progress?.status ?? .pending {
        case .running: return Color.accentColor.opacity(0.10)
        case .failed: return Color.red.opacity(0.08)
        default: return Color.clear
        }
    }
}

// MARK: - Log level helpers

private extension FlowExecutor.LogEntry.Level {
    var icon: String {
        switch self {
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .info: return .primary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: - Flow Run Window

/// Presents the live flow-run status in a real resizable window (not a modal
/// sheet), matching the Flow Report. Non-modal by design: the run keeps going
/// in the background even if the window is closed, so users can keep working.
/// Frame/position persist across launches.
@MainActor
final class FlowRunWindowController: NSObject, NSWindowDelegate {
    static let shared = FlowRunWindowController()
    private var window: NSWindow?

    func present(
        executor: FlowExecutor,
        flow: Flow,
        databaseManager: DatabaseManager,
        onClose: @escaping () -> Void
    ) {
        let root = FlowRunView(
            executor: executor,
            flow: flow,
            databaseManager: databaseManager
        ) { [weak self] in
            onClose()
            self?.close()
        }

        if let window {
            window.contentViewController = NSHostingController(rootView: root)
            window.makeKeyAndOrderFront(nil)
            window.makeMain()
            return
        }

        let controller = NSHostingController(rootView: root)
        let mask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
            styleMask: mask,
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.title = "Flow Run"
        window.minSize = NSSize(width: 640, height: 460)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let autosave = NSWindow.FrameAutosaveName("AnubisFlowRunWindow")
        if !window.setFrameAutosaveName(autosave) {
            window.center()
        } else if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            window.setContentSize(NSSize(width: 960, height: 700))
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
