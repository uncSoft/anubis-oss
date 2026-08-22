//
//  anubisTests.swift
//  anubisTests
//
//  Created by J T on 1/25/26.
//

import Testing
import Foundation
@testable import anubis

struct anubisTests {

    // MARK: - InferenceStats metric formulas

    private func stats(
        promptTokens: Int = 44,
        completionTokens: Int,
        totalDuration: TimeInterval = 60,
        promptEvalDuration: TimeInterval = 0.5,
        evalDuration: TimeInterval,
        reasoningTokens: Int = 0,
        reasoningDuration: TimeInterval = 0,
        reportedTokensPerSecond: Double? = nil
    ) -> InferenceStats {
        InferenceStats(
            totalTokens: promptTokens + completionTokens,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalDuration: totalDuration,
            promptEvalDuration: promptEvalDuration,
            evalDuration: evalDuration,
            loadDuration: 0,
            contextLength: promptTokens + completionTokens,
            reasoningTokens: reasoningTokens,
            reasoningDuration: reasoningDuration,
            reportedTokensPerSecond: reportedTokensPerSecond
        )
    }

    @Test func tokensPerSecondCountsAllGeneratedTokens() {
        let s = stats(completionTokens: 500, evalDuration: 10)
        #expect(abs(s.tokensPerSecond - 50) < 0.001)
    }

    /// Regression for the leaderboard's 5,000–29,000 tok/s rows: a
    /// reasoning-dominated run must NOT divide the handful of visible tokens
    /// by a near-zero duration difference.
    @Test func reasoningDominatedRunDoesNotExplode() {
        // 2049 tokens in 46.78s, 2048 of them reasoning over 46.78s —
        // the old visible-output formula returned 15,621 tok/s here.
        let s = stats(
            completionTokens: 2049,
            evalDuration: 46.78,
            reasoningTokens: 2048,
            reasoningDuration: 46.7806
        )
        #expect(s.tokensPerSecond > 40 && s.tokensPerSecond < 45)
    }

    @Test func allReasoningRunStillHasThroughput() {
        let s = stats(
            completionTokens: 2048,
            evalDuration: 63.03,
            reasoningTokens: 2048,
            reasoningDuration: 63.03
        )
        #expect(abs(s.tokensPerSecond - 2048.0 / 63.03) < 0.01)
    }

    @Test func backendReportedRateWinsOverDerivation() {
        let s = stats(completionTokens: 500, evalDuration: 10, reportedTokensPerSecond: 48.5)
        #expect(s.tokensPerSecond == 48.5)
    }

    @Test func averageTokenLatencyIsReciprocalOfThroughput() {
        let derived = stats(completionTokens: 500, evalDuration: 10)
        #expect(derived.averageTokenLatencyMs != nil)
        #expect(abs(derived.averageTokenLatencyMs! - 20) < 0.001)

        // Must also hold when the backend reports its own rate (oMLX,
        // llama.cpp) — the old formula ignored reportedTokensPerSecond and
        // produced a latency inconsistent with the displayed tok/s.
        let reported = stats(completionTokens: 500, evalDuration: 10, reportedTokensPerSecond: 40)
        #expect(abs(reported.averageTokenLatencyMs! - 25) < 0.001)
    }

    /// Issue #30: zero generated tokens must yield nil, never 0.
    @Test func zeroTokenRunHasUndefinedLatency() {
        let s = stats(completionTokens: 0, evalDuration: 0)
        #expect(s.averageTokenLatencyMs == nil)
        #expect(s.tokensPerSecond == 0)
    }

    @Test func promptProcessingSpeedUsesPromptEvalDuration() {
        let s = stats(completionTokens: 100, evalDuration: 10)
        #expect(abs(s.promptProcessingSpeed - 44.0 / 0.5) < 0.001)
    }
}
