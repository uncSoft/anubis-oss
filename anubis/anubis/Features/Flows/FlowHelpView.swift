//
//  FlowHelpView.swift
//  anubis
//
//  Inline documentation for the Flow Builder. Surfaced via the ?
//  button in the Flows sidebar header. Long-form rather than tooltip
//  since the For Each semantics in particular need a worked example
//  to click - the inspector copy is too tight to spell them out.
//

import SwiftUI

struct FlowHelpView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    overviewSection
                    workflowSection
                    stepCatalog
                    forEachDeepDive
                    commonPatterns
                    warningsSection
                    runningSection
                }
                .padding(Spacing.lg)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)   // center within scroll view
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 840, minHeight: 600, idealHeight: 760)
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text("Flow Builder Help").font(.headline)
                Text("How chains, repetitions, and For Each iteration work").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(Spacing.md)
    }

    private var footer: some View {
        HStack {
            Text("Tip: open this sheet any time from the ? in the Flows sidebar header.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Got it") { onClose() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(Spacing.md)
    }

    // MARK: - Sections

    private var overviewSection: some View {
        section(
            icon: "point.3.connected.trianglepath.dotted",
            title: "What is a Flow?"
        ) {
            Text("A Flow is a saved sequence of benchmark steps. Instead of clicking Run by hand for each model, prompt, or repetition, you author the sequence once and play it back. Anubis records every individual run (so it shows up in your normal Run History) and bundles them into a single Flow Report you can share.")
            Text("Flows are good for:")
            bullets([
                "Comparing N models on the same prompt",
                "Repeating one config to get mean ± 95% confidence intervals",
                "Cold-start vs warm-start measurements",
                "Sweeping over quantizations (Q4 vs Q8) or prompt variants",
                "Hands-off batch runs you publish straight to YouTube/socials",
            ])
        }
    }

    private var workflowSection: some View {
        section(
            icon: "hand.draw",
            title: "The editor"
        ) {
            Text("The editor has three panes:")
            bullets([
                "**Left – Palette**: every step type you can add. Click to append; drag onto the step list for precise placement.",
                "**Middle – Step List**: your flow, top-down execution order. Reorder by dragging or using the ↑/↓ chevrons. Containers (Repeat, For Each) nest their children with an indented rail.",
                "**Right – Inspector**: edits the currently selected step. Different controls per step type.",
            ])
            Text("The header chip on the top right tells you how many Run Benchmark invocations your flow will produce, multiplied through all containers (e.g. \"15 runs\" for 3 models × 5 reps).")
        }
    }

    private var stepCatalog: some View {
        section(
            icon: "list.bullet.rectangle",
            title: "Step types at a glance"
        ) {
            Text("Steps execute top-to-bottom. **State setters** change the running context every later Run uses; **action** steps produce results; **management** steps clean up between runs.")

            VStack(alignment: .leading, spacing: 6) {
                stepRow("server.rack", "Set Backend", "Choose Ollama / LM Studio / Apple Intelligence. Stays in effect for every subsequent Run until you change it.")
                stepRow("cube.box", "Set Model", "Pick a model on the current backend.")
                stepRow("text.bubble", "Set Prompt", "The text the model is asked to generate from. Multi-line.")
                stepRow("slider.horizontal.3", "Set Parameters", "Temperature, top-p, max tokens, seed strategy (random vs fixed).")
                stepRow("play.fill", "Run Benchmark", "Executes one inference using the current context. Produces one BenchmarkSession in Run History.")
                stepRow("repeat", "Repeat × N", "Container - runs its child body N times. Reps are aggregated into a BenchmarkRunGroup (mean ± 95% CI).")
                stepRow("rectangle.stack", "For Each Model", "Container - iterates over a list of model names, running its body once per model.")
                stepRow("text.append", "For Each Prompt", "Container - same, but over prompt texts.")
                stepRow("eject", "Unload Model", "Asks Ollama to evict the active model from memory. No-op on other backends.")
                stepRow("arrow.triangle.2.circlepath", "Reset Connection", "Tears down + rebuilds the backend's URLSession.")
                stepRow("snowflake", "Cool Down", "Pauses execution - either a fixed wait or until thermal state returns to nominal.")
                stepRow("note.text", "Annotate", "Free-text marker that shows up in the report and run log.")
            }
        }
    }

    private var forEachDeepDive: some View {
        section(
            icon: "rectangle.stack",
            title: "For Each - the rules"
        ) {
            Text("For Each Model and For Each Prompt are how you batch one flow over many values. Two rules to keep in mind:")

            ruleCard(
                number: "1",
                title: "For Each *replaces* the corresponding Set step inside the loop body.",
                body: "Inside a For Each Model, the current model is whatever value the iterator just picked - any prior Set Model becomes irrelevant for that iteration. The lint chip will flag a Set Model that sits right before a For Each Model: it never takes effect."
            )

            ruleCard(
                number: "2",
                title: "Nested containers multiply.",
                body: "Total runs = (outer count) × (inner count) × (deeper). Three models × two prompts × five reps = 30 BenchmarkSessions."
            )

            Text("Worked example - comparing 2 quantizations × 5 reps:")
            codeBlock("""
            Set Backend       Ollama
            Set Prompt        "Write a haiku about Anubis."
            Set Parameters    temp 0.7, max 256
            For Each Model    [llama3.2:3b-q4, llama3.2:3b-q8]
              Repeat × 5
                Run Benchmark
              Unload Model
            """)
            Text("Produces 10 sessions (2 models × 5 reps). Each model gets a BenchmarkRunGroup with its own mean ± 95% CI. The unload between iterations forces a cold start so timings don't bleed across models.")

            Text("Worked example - same prompt across 3 different models, with a cooldown:")
            codeBlock("""
            Set Backend       Ollama
            Set Prompt        "Summarise Hamlet in 100 words."
            Set Parameters    temp 0.7, max 512
            For Each Model    [llama3.2:1b, llama3.2:3b, qwen2.5:3b]
              Repeat × 3
                Run Benchmark
              Cool Down        5 seconds
              Unload Model
            """)
            Text("9 sessions total. The Flow Report ranks the three models by mean tok/s.")

            Text("**Common mistakes the lint chip will catch:**")
            bullets([
                "Set Model followed by For Each Model - the Set never runs.",
                "For Each with a blank entry in the list - that iteration fails at runtime.",
                "Empty For Each body - nothing to execute per iteration.",
                "Run Benchmark with no prior Set Backend / Set Model / Set Prompt - fails immediately.",
            ])
        }
    }

    private var commonPatterns: some View {
        section(
            icon: "lightbulb",
            title: "Common patterns"
        ) {
            Text("Start from a template (sidebar + → New from Template). Each one is a real working flow you can edit or use as-is:")
            bullets([
                "**Quick Smoke Test** - the minimum viable flow. Use this as a scaffold.",
                "**Repeated Run (5×)** - one model × 5 reps with random seed. Gets mean ± CI without sampler shenanigans.",
                "**Cold vs Warm Start** - unload, time a cold run, time a warm run. The classic TTFT comparison.",
                "**Multi-Model Comparison** - For Each Model with cooldown + unload between iterations.",
                "**Q4 vs Q8 Quantization** - same family, two quants, 5 reps each.",
                "**Prompt Variants** - one model, multiple prompts of varying complexity.",
            ])
        }
    }

    private var warningsSection: some View {
        section(
            icon: "exclamationmark.triangle.fill",
            title: "Warnings and lint"
        ) {
            Text("The editor analyses your flow as you build it. Any step with a problem gets a yellow ⚠ next to its name and an orange border. The header shows a count chip - click it for a popover listing every warning. Each row in the popover is a button that jumps to the offending step.")
            Text("Warnings don't block running - sometimes you genuinely want a setup-only flow. They're hints, not blockers.")
        }
    }

    private var runningSection: some View {
        section(
            icon: "play.fill",
            title: "Running a flow + reading the report"
        ) {
            Text("Hit the green Run button (⌘R) in the editor header. The Run sheet shows live progress: a step tree with checkmarks/spinners, a scrollback log, and a progress bar reading \"Run 7 of 30\".")
            Text("When the flow finishes, the View Report button (⇧⌘R) opens the Flow Report - a YouTube-ready 16:9 or 1:1 card with the leaderboard and methodology. Export as PNG (2× retina) or CSV.")
            Text("Past runs live in the **Run History** section of the sidebar. Click any row to reopen its report. Right-click to delete one; the section header menu has Clear All History… (the BenchmarkSessions survive - they stay in the Benchmark tab's Run History).")
        }
    }

    // MARK: - Building blocks

    private func section<Content: View>(
        icon: String,
        title: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                Text(title).font(.title3.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                content()
            }
            .font(.body)
            .foregroundStyle(.primary)
        }
    }

    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundStyle(.tint)
                    Text(.init(item))    // markdown for **bold**
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func stepRow(_ icon: String, _ name: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 22, height: 22)
                .foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.tint.opacity(0.8)))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold))
                Text(desc).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func ruleCard(number: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 18, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.tint))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(body).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: CornerRadius.md))
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.10), in: RoundedRectangle(cornerRadius: CornerRadius.sm))
    }
}

// Local shorthand - matches the editor's own .tint conventions.
private extension Color {
    static var tint: Color { .accentColor }
}
