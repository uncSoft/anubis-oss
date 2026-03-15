//
//  MetricsCard.swift
//  anubis
//
//  Created on 2026-01-25.
//

import SwiftUI

/// Card displaying a single metric value
struct MetricsCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    var available: Bool = true
    var subtitle: String? = nil
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let help = help {
                    HelpButton(text: help)
                }
                if !available {
                    Text("N/A")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Text(available ? value : "—")
                .font(.anubisMetricSmall)
                .foregroundStyle(available ? .primary : .tertiary)
                .contentTransition(.identity)

            // Always show subtitle row to maintain consistent height
            Text(subtitle ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .opacity(subtitle != nil ? 1 : 0)
        }
        .metricCardStyle()
    }
}

/// Help button with popover explanation
struct HelpButton: View {
    let text: String
    @State private var showingHelp = false

    var body: some View {
        Button {
            showingHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .popover(isPresented: $showingHelp, arrowEdge: .top) {
            Text(text)
                .font(.caption)
                .padding(Spacing.sm)
                .frame(maxWidth: 250)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Compact card for dense metric layouts (40% smaller than MetricsCard)
struct CompactMetricsCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    var available: Bool = true
    var subtitle: String? = nil
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                if let help = help {
                    HelpButton(text: help)
                }
                if !available {
                    Text("N/A")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
            }

            Text(available ? value : "—")
                .font(.anubisMetricCompact)
                .foregroundStyle(available ? .primary : .tertiary)
                .contentTransition(.identity)

            // Always render subtitle row to maintain consistent card height
            Text(subtitle ?? " ")
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
                .opacity(subtitle != nil ? 1 : 0)
        }
        .compactMetricCardStyle()
    }
}

/// Compact model memory card for dense layouts
struct CompactModelMemoryCard: View {
    let total: Int64
    var isOllamaBackend: Bool = true

    private let helpText = "Memory used by the loaded model in unified memory. Reported by Ollama's /api/ps endpoint (size_vram field). On Apple Silicon, GPU and CPU share the same memory pool."

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: "memorychip")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.chartMemory)
                Text("Model Memory")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                HelpButton(text: helpText)
                if !isOllamaBackend {
                    Text("N/A")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
            }

            if !isOllamaBackend {
                Text("—")
                    .font(.anubisMetricCompact)
                    .foregroundStyle(.tertiary)
            } else if total > 0 {
                Text(Formatters.bytes(total))
                    .font(.anubisMetricCompact)
            } else {
                Text("—")
                    .font(.anubisMetricCompact)
                    .foregroundStyle(.tertiary)
            }

            Text(subtitleText)
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary.opacity(subtitleDimmed ? 0.6 : 1))
        }
        .compactMetricCardStyle()
    }

    private var subtitleText: String {
        if !isOllamaBackend { return "Ollama only" }
        else if total > 0 { return "Unified Memory" }
        else { return "Waiting for model..." }
    }

    private var subtitleDimmed: Bool {
        !isOllamaBackend || total == 0
    }
}

/// Larger metric card for primary values
struct PrimaryMetricsCard: View {
    let title: String
    let value: String
    let subtitle: String?
    let icon: String
    let color: Color

    init(title: String, value: String, subtitle: String? = nil, icon: String, color: Color) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.icon = icon
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
                Spacer()
            }

            Text(value)
                .font(.anubisMetric)
                .contentTransition(.identity)

            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }
}

#Preview("Metrics Cards") {
    VStack(spacing: Spacing.md) {
        HStack(spacing: Spacing.md) {
            MetricsCard(
                title: "Tokens/sec",
                value: "42.5 tok/s",
                icon: "bolt.fill",
                color: .chartTokens,
                subtitle: "Peak: 58.2 tok/s",
                help: "Average: total tokens ÷ generation time. Peak: highest instantaneous rate between sample intervals."
            )
            MetricsCard(
                title: "GPU",
                value: "78%",
                icon: "gpu",
                color: .chartGPU,
                help: "GPU utilization from IOReport."
            )
        }

        HStack(spacing: Spacing.md) {
            MetricsCard(
                title: "CPU",
                value: "23%",
                icon: "cpu",
                color: .chartCPU,
                help: "CPU utilization across all cores."
            )
            MetricsCard(
                title: "ANE Power",
                value: "N/A",
                icon: "bolt.horizontal.fill",
                color: .chartANE,
                available: false,
                help: "Neural Engine power consumption."
            )
        }

        PrimaryMetricsCard(
            title: "Performance",
            value: "42.5 tok/s",
            subtitle: "llama3.2:3b • Ollama",
            icon: "gauge.with.dots.needle.67percent",
            color: .chartTokens
        )
    }
    .padding()
    .frame(width: 400)
}
