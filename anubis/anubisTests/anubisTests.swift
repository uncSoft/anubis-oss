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

    // MARK: - OpenAI-compat stream finalization (timing fallback chains)

    private func decodeChunk(_ json: String) throws -> OpenAIChatStreamResponse {
        try JSONDecoder().decode(OpenAIChatStreamResponse.self, from: Data(json.utf8))
    }

    /// llama-server's final stream chunk, shape verified against llama.cpp
    /// master (timings ride the trailing usage chunk, durations in ms).
    private static let llamaCppFinalChunk = #"""
    {"id":"chatcmpl-x","object":"chat.completion.chunk","created":1724300000,"model":"m","choices":[],"usage":{"prompt_tokens":56,"completion_tokens":128,"total_tokens":184},"timings":{"cache_n":48,"prompt_n":8,"prompt_ms":42.5,"prompt_per_token_ms":5.3,"prompt_per_second":188.2,"predicted_n":128,"predicted_ms":1600.0,"predicted_per_token_ms":12.5,"predicted_per_second":80.0}}
    """#

    @Test func llamaCppTimingsDecodeFromFinalChunk() throws {
        let chunk = try decodeChunk(Self.llamaCppFinalChunk)
        let t = try #require(chunk.timings)
        #expect(t.promptN == 8)
        #expect(t.cacheN == 48)
        #expect(t.promptMs == 42.5)
        #expect(t.predictedN == 128)
        #expect(t.predictedMs == 1600.0)
        #expect(t.predictedPerSecond == 80.0)
        #expect(chunk.usage?.hasServerTiming == false)
    }

    @Test func finalizeUsesLlamaCppTimingsOverWallClock() throws {
        let chunk = try decodeChunk(Self.llamaCppFinalChunk)
        var state = StreamState()
        state.markFirstChunk(Date())
        let s = state.finalize(startTime: Date().addingTimeInterval(-10),
                               usage: chunk.usage, timings: chunk.timings)
        // ms → s conversion, decode-loop values win over chunk-arrival timing
        #expect(abs(s.evalDuration - 1.6) < 0.0001)
        #expect(abs(s.promptEvalDuration - 0.0425) < 0.0001)
        #expect(s.reportedTokensPerSecond == 80.0)
        #expect(s.tokensPerSecond == 80.0)
        // usage present → its counts win; llama.cpp TTFT is prefill-only,
        // so client wall clock stays authoritative for TTFT
        #expect(s.completionTokens == 128)
        #expect(s.promptTokens == 56)
        #expect(s.serverReportedTTFT == nil)
        // end-to-end wall total, not the server's decode window
        #expect(abs(s.totalDuration - 10) < 1.0)
    }

    @Test func finalizeUsesTimingsTokenCountsWhenUsageAbsent() throws {
        let chunk = try decodeChunk(Self.llamaCppFinalChunk)
        var state = StreamState()
        let s = state.finalize(startTime: Date(), usage: nil, timings: chunk.timings)
        #expect(s.completionTokens == 128)          // predicted_n
        #expect(s.promptTokens == 56)               // prompt_n + cache_n
    }

    @Test func finalizePrefersOmlxUsageTiming() throws {
        let chunk = try decodeChunk(#"""
        {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":200,"total_tokens":300,"time_to_first_token":0.35,"prompt_eval_duration":0.3,"generation_duration":4.0,"prompt_tokens_per_second":333.3,"generation_tokens_per_second":50.0,"model_load_duration":1.2,"total_time":4.4}}
        """#)
        let usage = try #require(chunk.usage)
        #expect(usage.hasServerTiming)
        var state = StreamState()
        let s = state.finalize(startTime: Date().addingTimeInterval(-6), usage: usage, timings: nil)
        #expect(s.evalDuration == 4.0)
        #expect(s.promptEvalDuration == 0.3)
        #expect(s.reportedTokensPerSecond == 50.0)
        #expect(s.serverReportedTTFT == 0.35)
        #expect(s.reportedPromptTokensPerSecond == 333.3)
        #expect(s.loadDuration == 1.2)
        // avg latency must be the reciprocal of the REPORTED rate
        #expect(abs(s.averageTokenLatencyMs! - 20.0) < 0.0001)
    }

    @Test func finalizeWallClockFallbackWhenServerReportsNothing() throws {
        let chunk = try decodeChunk(#"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":40,"total_tokens":50}}"#)
        var state = StreamState()
        let start = Date().addingTimeInterval(-5)
        state.markFirstChunk(start.addingTimeInterval(1))   // first chunk 1 s in
        let s = state.finalize(startTime: start, usage: chunk.usage, timings: nil)
        #expect(abs(s.promptEvalDuration - 1.0) < 0.5)      // start → first chunk
        #expect(abs(s.evalDuration - 4.0) < 0.5)            // first chunk → now
        #expect(s.reportedTokensPerSecond == nil)
        #expect(s.serverReportedTTFT == nil)
        #expect(s.completionTokens == 40)
    }

    /// Backend gives one completion count including reasoning; the local
    /// reasoning/output piece counts scale it into a token split.
    @Test func finalizeScalesReasoningSplitToBackendCount() throws {
        let chunk = try decodeChunk(#"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":200,"total_tokens":210}}"#)
        var state = StreamState()
        state.reasoningTokens = 30    // local piece counts, 30% reasoning
        state.outputTokens = 70
        let s = state.finalize(startTime: Date(), usage: chunk.usage, timings: nil)
        #expect(s.completionTokens == 200)
        #expect(s.reasoningTokens == 60)              // 30% of backend's 200
    }
}
