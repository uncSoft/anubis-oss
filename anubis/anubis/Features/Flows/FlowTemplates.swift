//
//  FlowTemplates.swift
//  anubis
//
//  Curated starter flows shipped with the app. Picking a template
//  creates a fresh Flow record pre-populated with the template's
//  steps — the user then renames it and edits as needed. Templates
//  use placeholder model names / prompts where the value is up to
//  the user so the flow lints with a clear pointer to what to fill
//  in (rather than silently running a wrong default).
//

import Foundation

struct FlowTemplate: Identifiable {
    let id: String
    let name: String
    let description: String
    let iconName: String
    let steps: [FlowStep]

    /// Stable catalog. The sidebar menu surfaces these in declaration
    /// order — keep simple/common ones first so new users see the
    /// shortest path to a useful run.
    static let catalog: [FlowTemplate] = [
        smokeTest,
        repeatedRun,
        coldVsWarm,
        modelSweep,
        quantSweep,
        promptVariants,
    ]
}

// MARK: - Templates

extension FlowTemplate {
    /// One backend, one model, one prompt, one run. The "hello world"
    /// of flows — useful both as a smoke test and as a starting
    /// scaffold for users learning the editor.
    static let smokeTest = FlowTemplate(
        id: "smoke-test",
        name: "Quick Smoke Test",
        description: "Single backend, model, prompt, one run. The minimum viable flow.",
        iconName: "checkmark.seal",
        steps: [
            .init(kind: .setBackend(.init(type: .ollama, openAIConfigId: nil))),
            .init(kind: .setModel("llama3.2:3b")),
            .init(kind: .setPrompt(.inline(text: "Write a haiku about Anubis."))),
            .init(kind: .setParameters(.default)),
            .init(kind: .runBenchmark),
        ]
    )

    /// Five repetitions of the same config so the report shows mean ±
    /// 95% CI rather than a single noisy number. The default "honest"
    /// measurement most users want.
    static let repeatedRun = FlowTemplate(
        id: "repeated-run",
        name: "Repeated Run (5×)",
        description: "Same model + prompt, 5 reps with random seed. Reports mean ± 95% CI.",
        iconName: "repeat.circle",
        steps: [
            .init(kind: .setBackend(.init(type: .ollama, openAIConfigId: nil))),
            .init(kind: .setModel("llama3.2:3b")),
            .init(kind: .setPrompt(.inline(text: "Explain time-to-first-token in one paragraph."))),
            .init(kind: .setParameters(.default)),
            .init(kind: .repeatN(count: 5, body: [
                .init(kind: .runBenchmark),
            ])),
        ]
    )

    /// Unload model → cold run → warm run. The classic comparison
    /// every reviewer wants to see.
    static let coldVsWarm = FlowTemplate(
        id: "cold-vs-warm",
        name: "Cold vs Warm Start",
        description: "Unload model, time the cold run, then a warm follow-up. Watch the TTFT gap.",
        iconName: "thermometer.sun",
        steps: [
            .init(kind: .setBackend(.init(type: .ollama, openAIConfigId: nil))),
            .init(kind: .setModel("llama3.2:3b")),
            .init(kind: .setPrompt(.inline(text: "Summarise the plot of Hamlet in 100 words."))),
            .init(kind: .setParameters(.default)),
            .init(kind: .unloadModel),
            .init(kind: .annotate(text: "Cold run — model loads from disk")),
            .init(kind: .runBenchmark),
            .init(kind: .annotate(text: "Warm run — model resident in memory")),
            .init(kind: .runBenchmark),
        ]
    )

    /// Three models, three reps each. Produces a leaderboard with
    /// per-model bars in the report.
    static let modelSweep = FlowTemplate(
        id: "model-sweep",
        name: "Multi-Model Comparison",
        description: "Iterate over a list of models, 3 reps each. Produces a per-model leaderboard.",
        iconName: "rectangle.stack",
        steps: [
            .init(kind: .setBackend(.init(type: .ollama, openAIConfigId: nil))),
            .init(kind: .setPrompt(.inline(text: "Write a short story about a robot learning to bake."))),
            .init(kind: .setParameters(.default)),
            .init(kind: .forEachModel(
                models: ["llama3.2:1b", "llama3.2:3b", "qwen2.5:3b"],
                body: [
                    .init(kind: .repeatN(count: 3, body: [
                        .init(kind: .runBenchmark),
                    ])),
                    .init(kind: .coolDown(.fixed(seconds: 5))),
                    .init(kind: .unloadModel),
                ]
            )),
        ]
    )

    /// Same family, different quantizations. Demonstrates why
    /// quantization choice matters on Apple Silicon.
    static let quantSweep = FlowTemplate(
        id: "quant-sweep",
        name: "Q4 vs Q8 Quantization",
        description: "Same model in two quantizations, 5 reps each. Highlights the speed/quality trade-off.",
        iconName: "cube.transparent",
        steps: [
            .init(kind: .setBackend(.init(type: .ollama, openAIConfigId: nil))),
            .init(kind: .setPrompt(.inline(text: "List the prime numbers under 100 and explain why 1 isn't prime."))),
            .init(kind: .setParameters(.default)),
            .init(kind: .forEachModel(
                models: ["llama3.2:3b-instruct-q4_K_M", "llama3.2:3b-instruct-q8_0"],
                body: [
                    .init(kind: .repeatN(count: 5, body: [
                        .init(kind: .runBenchmark),
                    ])),
                    .init(kind: .unloadModel),
                ]
            )),
        ]
    )

    /// One model, several prompts. Useful for spotting how prompt
    /// complexity affects throughput.
    static let promptVariants = FlowTemplate(
        id: "prompt-variants",
        name: "Prompt Variants",
        description: "One model, multiple prompts. See how prompt complexity affects throughput.",
        iconName: "text.append",
        steps: [
            .init(kind: .setBackend(.init(type: .ollama, openAIConfigId: nil))),
            .init(kind: .setModel("llama3.2:3b")),
            .init(kind: .setParameters(.default)),
            .init(kind: .forEachPrompt(
                prompts: [
                    "Write a haiku about Anubis.",
                    "Explain monads in functional programming with a Swift example.",
                    "Summarise the entire history of computing in 200 words.",
                ],
                body: [
                    .init(kind: .repeatN(count: 3, body: [
                        .init(kind: .runBenchmark),
                    ])),
                ]
            )),
        ]
    )
}
