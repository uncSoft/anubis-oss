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

    // MARK: - LM Studio native stream parser
    //
    // SSE lines below are verbatim from a live LM Studio /api/v1/chat
    // session (Aug 2026), abbreviated.

    @Test func lmStudioNativeParserReadsReasoningRun() {
        var parser = LMStudioNativeStreamParser()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let lines = [
            #"data: {"type":"chat.start"}"#,
            #"data: {"type":"model_load.start","model_instance_id":"qwen/qwen3.6-35b-a3b"}"#,
            #"data: {"type":"model_load.progress","progress":0.5}"#,
            #"data: {"type":"model_load.end","model_instance_id":"qwen/qwen3.6-35b-a3b","load_time_seconds":24.146}"#,
            #"data: {"type":"prompt_processing.start"}"#,
            #"data: {"type":"prompt_processing.end"}"#,
            #"data: {"type":"reasoning.start"}"#,
            #"data: {"type":"reasoning.delta","content":"Here"}"#,
            #"data: {"type":"reasoning.delta","content":"'s a thinking process"}"#,
            #"data: {"type":"reasoning.end"}"#,
            #"data: {"type":"message.start"}"#,
            #"data: {"type":"message.delta","content":"391"}"#,
            #"data: {"type":"message.end"}"#,
            #"data: {"type":"chat.end","result":{"model_instance_id":"qwen/qwen3.6-35b-a3b","output":[],"stats":{"input_tokens":19,"total_output_tokens":79,"reasoning_output_tokens":70,"tokens_per_second":44.58598726114649,"time_to_first_token_seconds":0.931,"model_load_time_seconds":24.146}}}"#,
        ]
        var texts: [String] = []
        for (i, line) in lines.enumerated() {
            let chunks = parser.handle(line: line, now: t0.addingTimeInterval(Double(i)))
            texts.append(contentsOf: chunks.map(\.text))
        }
        #expect(texts == ["<think>", "Here", "'s a thinking process", "</think>", "391"])
        #expect(parser.sawChatEnd)

        let s = parser.finalize(startTime: t0.addingTimeInterval(-1), now: t0.addingTimeInterval(30))
        #expect(s.completionTokens == 79)
        #expect(s.promptTokens == 19)
        #expect(s.reasoningTokens == 70)
        #expect(s.loadDuration == 24.146)
        #expect(s.serverReportedTTFT == 0.931)
        #expect(s.tokensPerSecond == 44.58598726114649)
        // evalDuration derived from the reported rate, so they stay consistent
        #expect(abs(s.evalDuration - 79.0 / 44.58598726114649) < 0.001)
        // totalDuration is client end-to-end wall time
        #expect(abs(s.totalDuration - 31) < 0.001)
        #expect(s.serverReportedMetricsJSON?.contains("time_to_first_token_seconds") == true)
        // Server-measured timing must never be flagged as burst-suspicious
        #expect(!s.hasSuspiciousStreamTiming)
    }

    @Test func lmStudioNativeParserHandlesPlainRunAndUnknownEvents() {
        var parser = LMStudioNativeStreamParser()
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let lines = [
            "event: chat.start",  // event lines are ignored; only data: parsed
            #"data: {"type":"chat.start"}"#,
            #"data: {"type":"some.future.event","payload":123}"#,
            #"data: {"type":"message.delta","content":"Hi"}"#,
            #"data: {"type":"message.delta","content":" there"}"#,
            #"data: {"type":"chat.end","result":{"stats":{"input_tokens":16,"total_output_tokens":6,"reasoning_output_tokens":0,"tokens_per_second":89.9,"time_to_first_token_seconds":0.073}}}"#,
        ]
        var texts: [String] = []
        for line in lines {
            texts.append(contentsOf: parser.handle(line: line, now: t0).map(\.text))
        }
        #expect(texts == ["Hi", " there"])
        let s = parser.finalize(startTime: t0, now: t0.addingTimeInterval(0.2))
        #expect(s.completionTokens == 6)
        #expect(s.reasoningTokens == 0)
        #expect(s.loadDuration == 0)   // no JIT load this request
        #expect(s.reportedTokensPerSecond == 89.9)
    }

    /// Stream dies before chat.end: fall back to locally counted pieces and
    /// wall-clock timing rather than reporting nothing.
    @Test func lmStudioNativeParserSurvivesTruncatedStream() {
        var parser = LMStudioNativeStreamParser()
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        _ = parser.handle(line: #"data: {"type":"message.delta","content":"partial"}"#, now: t0)
        #expect(!parser.sawChatEnd)
        let s = parser.finalize(startTime: t0, now: t0.addingTimeInterval(5))
        #expect(s.completionTokens == 1)
        #expect(s.reportedTokensPerSecond == nil)
        #expect(abs(s.totalDuration - 5) < 0.001)
    }
}
