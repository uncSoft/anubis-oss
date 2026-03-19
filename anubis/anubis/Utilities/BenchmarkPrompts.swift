//
//  BenchmarkPrompts.swift
//  anubis
//
//  Created on 2026-01-26.
//

import Foundation

/// Preset prompts for quick benchmarking
struct BenchmarkPrompt: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let category: PromptCategory
    let prompt: String
    let expectedLength: ExpectedLength

    enum PromptCategory: String, CaseIterable {
        case reasoning = "Reasoning"
        case coding = "Coding"
        case creative = "Creative"
        case knowledge = "Knowledge"
        case instruction = "Instruction"
    }

    enum ExpectedLength: String {
        case short = "Short"      // ~50-100 tokens
        case medium = "Medium"    // ~200-400 tokens
        case long = "Long"        // ~500+ tokens
    }
}

extension BenchmarkPrompt {
    /// Curated set of benchmark prompts testing different capabilities
    static let presets: [BenchmarkPrompt] = [
        // Reasoning
        BenchmarkPrompt(
            name: "Logic Puzzle",
            category: .reasoning,
            prompt: """
            A farmer needs to cross a river with a wolf, a goat, and a cabbage. The boat can only carry the farmer and one item at a time. If left alone, the wolf will eat the goat, and the goat will eat the cabbage. How can the farmer get everything across safely? Explain your reasoning step by step.
            """,
            expectedLength: .medium
        ),

        BenchmarkPrompt(
            name: "Math Word Problem",
            category: .reasoning,
            prompt: """
            A train leaves Station A at 9:00 AM traveling at 60 mph toward Station B. Another train leaves Station B at 10:00 AM traveling at 80 mph toward Station A. If the stations are 280 miles apart, at what time will the trains meet? Show your work.
            """,
            expectedLength: .medium
        ),

        // Coding
        BenchmarkPrompt(
            name: "Algorithm Implementation",
            category: .coding,
            prompt: """
            Write a Python function that finds the longest palindromic substring in a given string. Include comments explaining your approach and analyze the time complexity.
            """,
            expectedLength: .medium
        ),

        BenchmarkPrompt(
            name: "Code Review",
            category: .coding,
            prompt: """
            Review this code and identify bugs, performance issues, and suggest improvements:

            def get_user_data(user_ids):
                results = []
                for id in user_ids:
                    data = database.query(f"SELECT * FROM users WHERE id = {id}")
                    if data:
                        results.append(data)
                return results
            """,
            expectedLength: .medium
        ),

        // Creative
        BenchmarkPrompt(
            name: "Short Story",
            category: .creative,
            prompt: """
            Write a short story (about 300 words) about an astronaut who discovers something unexpected on Mars. Include vivid sensory details and an emotional arc.
            """,
            expectedLength: .long
        ),

        BenchmarkPrompt(
            name: "Poetry",
            category: .creative,
            prompt: """
            Write a sonnet (14 lines, iambic pentameter, ABAB CDCD EFEF GG rhyme scheme) about the feeling of learning something new.
            """,
            expectedLength: .short
        ),

        // Knowledge
        BenchmarkPrompt(
            name: "Technical Explanation",
            category: .knowledge,
            prompt: """
            Explain how a transformer neural network architecture works, including the attention mechanism. Make it understandable to someone with basic programming knowledge but no ML background.
            """,
            expectedLength: .long
        ),

        BenchmarkPrompt(
            name: "Comparison Analysis",
            category: .knowledge,
            prompt: """
            Compare and contrast SQL and NoSQL databases. Discuss their strengths, weaknesses, and ideal use cases. Provide specific examples of when you would choose each.
            """,
            expectedLength: .medium
        ),

        // Reasoning (additional)
        BenchmarkPrompt(
            name: "Causal Reasoning",
            category: .reasoning,
            prompt: """
            A city noticed that neighborhoods with more ice cream trucks also have higher crime rates. The mayor proposes banning ice cream trucks to reduce crime. Write a detailed analysis of why this reasoning is flawed, identify the likely confounding variable, and explain the difference between correlation and causation using this example and two others.
            """,
            expectedLength: .long
        ),

        // Coding (additional)
        BenchmarkPrompt(
            name: "System Design",
            category: .coding,
            prompt: """
            Design a rate limiter for an API that supports:
            1. Per-user limits (100 requests/minute)
            2. Global limits (10,000 requests/minute)
            3. Burst allowance (up to 20 requests in 1 second, borrowed from the minute quota)

            Write the implementation in Python using a sliding window approach. Include the data structures, the core check-and-update logic, and explain how it handles edge cases like clock skew and distributed deployments.
            """,
            expectedLength: .long
        ),

        // Creative (additional)
        BenchmarkPrompt(
            name: "Dialogue Scene",
            category: .creative,
            prompt: """
            Write a tense dialogue scene between two chess grandmasters during a world championship match. One suspects the other of using engine assistance. The conversation happens during a bathroom break, away from cameras. Convey the accusation, denial, and power dynamics entirely through dialogue and brief action beats — no internal monologue. About 400 words.
            """,
            expectedLength: .long
        ),

        // Knowledge (additional)
        BenchmarkPrompt(
            name: "Historical Analysis",
            category: .knowledge,
            prompt: """
            Explain the economic and technological factors that led to the decline of the Roman Empire's western half while the eastern half (Byzantine Empire) survived for another millennium. Discuss at least four specific factors and how they interacted with each other.
            """,
            expectedLength: .long
        ),

        // Instruction Following (additional)
        BenchmarkPrompt(
            name: "Constrained Writing",
            category: .instruction,
            prompt: """
            Write exactly 6 sentences about the ocean. Each sentence must:
            1. Be exactly 10 words long
            2. Start with a different letter of the alphabet
            3. Not repeat any noun across sentences
            4. Include at least one color word per sentence

            After the sentences, verify each constraint is met with a brief checklist.
            """,
            expectedLength: .medium
        ),

        // Instruction Following
        BenchmarkPrompt(
            name: "Structured Output",
            category: .instruction,
            prompt: """
            Create a JSON object representing a book with the following fields: title, author, year, genres (array), rating (1-5), and a nested "publisher" object with name and location. Use "The Great Gatsby" as the example. Return only valid JSON, no explanation.
            """,
            expectedLength: .short
        ),

        BenchmarkPrompt(
            name: "Multi-Step Task",
            category: .instruction,
            prompt: """
            I need to plan a 3-day trip to Tokyo. For each day, provide:
            1. A theme for the day
            2. Three activities with approximate times
            3. One restaurant recommendation
            4. Estimated daily budget in USD

            Format as a clear itinerary with headers for each day.
            """,
            expectedLength: .long
        ),
    ]

    /// Group presets by category
    static var presetsByCategory: [PromptCategory: [BenchmarkPrompt]] {
        Dictionary(grouping: presets, by: { $0.category })
    }
}
