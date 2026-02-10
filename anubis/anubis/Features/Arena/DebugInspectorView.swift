//
//  DebugInspectorView.swift
//  anubis
//
//  Created on 2026-01-28.
//

import SwiftUI

/// Slim bottom bar that shows debug phase status.
/// When tapped, an expanded panel pops upward over sibling content.
///
/// Usage: place `DebugInspectorBar` at the bottom of a panel's VStack,
/// and wrap the content area above it with `DebugInspectorBar`'s overlay
/// via the `.debugInspectorOverlay()` pattern — or simply use
/// `DebugInspectorPanel` as the container that manages both.
struct DebugInspectorPanel: View {
    let debugState: DebugInspectorState
    var accentColor: Color = .secondary

    /// The main content this panel wraps (response + stats, etc.)
    let content: () -> AnyView

    @State private var isExpanded = false
    @State private var isJSONExpanded = false

    init(
        debugState: DebugInspectorState,
        accentColor: Color = .secondary,
        @ViewBuilder content: @escaping () -> some View
    ) {
        self.debugState = debugState
        self.accentColor = accentColor
        self.content = { AnyView(content()) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Main content fills the space; pad bottom when bar visible
            // so content isn't hidden behind the bar
            content()
                .padding(.bottom, debugState.phase != .idle ? 26 : 0)

            // Bottom bar + expanded panel
            if debugState.phase != .idle {
                VStack(spacing: 0) {
                    // Expanded detail panel (pops upward)
                    if isExpanded {
                        expandedContent
                            .transition(.move(edge: .bottom).combined(with: .blurReplace))
                    }

                    // Slim status bar — always in layout
                    debugBar
                }
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
            }
        }
    }

    // MARK: - Slim Bar

    private var debugBar: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text("Debug")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                Circle()
                    .fill(phaseColor)
                    .frame(width: 6, height: 6)

                Text(phaseLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            requestSummary
            streamingMetrics

            if let errorMessage = debugState.errorMessage {
                errorSection(errorMessage)
            }

            if let json = debugState.requestJSON, !json.isEmpty {
                rawJSONSection(json)
            }
        }
        .padding(Spacing.sm)
        .background(Color.cardBackgroundElevated)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    // MARK: - Request Summary

    private var requestSummary: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], alignment: .leading, spacing: 2) {
            debugLabel("Endpoint")
            debugValue(debugState.endpointURL ?? "—", mono: true)

            debugLabel("Model")
            debugValue(debugState.modelId ?? "—")

            debugLabel("Backend")
            debugValue(debugState.backendType?.displayName ?? "—")

            if let temp = debugState.temperature {
                debugLabel("Temperature")
                debugValue(String(format: "%.1f", temp))
            }

            if let tp = debugState.topP {
                debugLabel("Top-P")
                debugValue(String(format: "%.2f", tp))
            }

            if let mt = debugState.maxTokens {
                debugLabel("Max Tokens")
                debugValue("\(mt)")
            }
        }
    }

    // MARK: - Streaming Metrics

    private var streamingMetrics: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ], alignment: .leading, spacing: 4) {
            debugLabel("Chunks")
            debugLabel("Bytes")
            debugLabel("TTFC")

            debugValue("\(debugState.chunksReceived)")
            debugValue(Formatters.bytes(Int64(debugState.bytesReceived)))
            debugValue(debugState.timeToFirstChunkMs.map { Formatters.milliseconds($0) } ?? "—")

            debugLabel("Elapsed")
            debugLabel("Chunks/sec")
            debugLabel("")

            debugValue(debugState.elapsed.map { Formatters.duration($0) } ?? "—")
            debugValue(debugState.chunksPerSecond.map { String(format: "%.1f", $0) } ?? "—")
            debugValue("")
        }
    }

    // MARK: - Error Section

    private func errorSection(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: CornerRadius.sm)
                .fill(Color.red.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.sm)
                        .strokeBorder(Color.red.opacity(0.2), lineWidth: 1)
                }
        }
    }

    // MARK: - Raw JSON Section

    private func rawJSONSection(_ json: String) -> some View {
        DisclosureGroup(isExpanded: $isJSONExpanded) {
            ScrollView {
                Text(json)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.xs)
            }
            .frame(maxHeight: 150)
            .background {
                RoundedRectangle(cornerRadius: CornerRadius.sm)
                    .fill(Color.black.opacity(0.03))
            }
        } label: {
            Text("Request JSON")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func debugLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func debugValue(_ text: String, mono: Bool = false) -> some View {
        Text(text)
            .font(mono ? .system(size: 10, design: .monospaced) : .caption2)
            .foregroundStyle(.primary)
            .lineLimit(1)
    }

    private var phaseColor: Color {
        switch debugState.phase {
        case .idle: return .gray
        case .connecting: return .yellow
        case .streaming: return .blue
        case .complete: return .green
        case .error: return .red
        }
    }

    private var phaseLabel: String {
        switch debugState.phase {
        case .idle:
            return "Idle"
        case .connecting:
            return "Connecting..."
        case .streaming:
            return "Streaming (\(debugState.chunksReceived) chunks)"
        case .complete:
            return "Complete (\(debugState.chunksReceived) chunks)"
        case .error:
            return "Error"
        }
    }
}
