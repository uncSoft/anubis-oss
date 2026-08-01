//
//  RunConditionsTests.swift
//  anubisTests
//
//  Covers the v12 run-condition fields: the thermal roll-up computed from a
//  session's samples, the derived flags, and their presence in CSV export.
//

import Testing
import Foundation
@testable import anubis

struct RunConditionsTests {

    // MARK: - Thermal summary

    @Test func thermalSummaryIsNilWithoutSamples() {
        let summary = BenchmarkSample.computeThermalSummary(from: [])
        #expect(summary.stateAtStart == nil)
        #expect(summary.nonNominalFraction == nil)
    }

    @Test func thermalSummaryIsZeroWhenEveryStateIsNominal() {
        let samples = (0..<4).map { _ in
            BenchmarkSample(sessionId: 1, thermalState: 0)
        }
        let summary = BenchmarkSample.computeThermalSummary(from: samples)
        #expect(summary.stateAtStart == 0)
        #expect(summary.nonNominalFraction == 0)
    }

    @Test func thermalSummaryCountsEveryNonNominalState() {
        // nominal, nominal, fair, serious -> half the run was under pressure
        let states = [0, 0, 1, 2]
        let samples = states.map { BenchmarkSample(sessionId: 1, thermalState: $0) }
        let summary = BenchmarkSample.computeThermalSummary(from: samples)
        #expect(summary.stateAtStart == 0)
        #expect(summary.nonNominalFraction == 0.5)
    }

    @Test func thermalSummaryTakesStateFromFirstSample() {
        let samples = [1, 0, 0].map { BenchmarkSample(sessionId: 1, thermalState: $0) }
        let summary = BenchmarkSample.computeThermalSummary(from: samples)
        #expect(summary.stateAtStart == 1)
    }

    @Test func thermalSummaryIgnoresSamplesMissingAState() {
        let samples = [
            BenchmarkSample(sessionId: 1, thermalState: nil),
            BenchmarkSample(sessionId: 1, thermalState: 1),
            BenchmarkSample(sessionId: 1, thermalState: nil),
        ]
        let summary = BenchmarkSample.computeThermalSummary(from: samples)
        // One usable sample, and it was non-nominal.
        #expect(summary.nonNominalFraction == 1.0)
        #expect(summary.stateAtStart == 1)
    }

    // MARK: - Derived flags

    @Test func runIsFlaggedWhenAnySampleWasNonNominal() {
        var session = makeSession()
        session.thermalStateAtStart = 0
        session.thermalNonNominalFraction = 0.1
        #expect(session.ranUnderThermalPressure)
    }

    @Test func runIsFlaggedWhenItStartedNonNominalEvenAtZeroFraction() {
        var session = makeSession()
        session.thermalStateAtStart = 2
        session.thermalNonNominalFraction = 0
        #expect(session.ranUnderThermalPressure)
    }

    @Test func nominalRunIsNotFlagged() {
        var session = makeSession()
        session.thermalStateAtStart = 0
        session.thermalNonNominalFraction = 0
        #expect(!session.ranUnderThermalPressure)
    }

    @Test func tokenCapFlagFollowsFinishReason() {
        var session = makeSession()
        session.finishReason = "length"
        #expect(session.hitTokenCap)
        session.finishReason = "stop"
        #expect(!session.hitTokenCap)
        session.finishReason = nil
        #expect(!session.hitTokenCap)
    }

    // MARK: - Request parameters

    @Test func requestParametersAreRecordedBeforeCompletion() {
        var session = makeSession()
        session.recordRequestParameters(
            maxTokens: 512, temperature: 0.7, topP: 0.9, seed: 42
        )
        #expect(session.maxTokensRequested == 512)
        #expect(session.temperature == 0.7)
        #expect(session.topP == 0.9)
        #expect(session.seed == 42)
    }

    // MARK: - Completion plumbing

    /// The path a real run takes: stats carry the backend's finish_reason,
    /// the sample roll-up carries thermal, and `complete` lands both.
    @Test func completeCarriesFinishReasonAndThermalOntoTheSession() {
        var session = makeSession()
        let stats = InferenceStats(
            totalTokens: 534,
            promptTokens: 22,
            completionTokens: 512,
            totalDuration: 10.4,
            promptEvalDuration: 0.5,
            evalDuration: 9.9,
            loadDuration: 0,
            contextLength: 534,
            finishReason: "length"
        )
        let thermal = BenchmarkSample.computeThermalSummary(
            from: [0, 0, 1, 1].map { BenchmarkSample(sessionId: 1, thermalState: $0) }
        )

        session.complete(with: stats, response: "ok", thermalSummary: thermal)

        #expect(session.finishReason == "length")
        #expect(session.hitTokenCap)
        #expect(session.thermalNonNominalFraction == 0.5)
        #expect(session.thermalStateAtStart == 0)
        #expect(session.ranUnderThermalPressure)
        #expect(session.status == .completed)
    }

    /// A backend that reports no finish_reason must leave the field nil rather
    /// than implying the run finished on its own.
    @Test func completeLeavesFinishReasonNilWhenTheBackendOmitsIt() {
        var session = makeSession()
        let stats = InferenceStats(
            totalTokens: 10, promptTokens: 2, completionTokens: 8,
            totalDuration: 1, promptEvalDuration: 0.1, evalDuration: 0.9,
            loadDuration: 0, contextLength: 10
        )
        session.complete(with: stats, response: "ok")
        #expect(session.finishReason == nil)
        #expect(!session.hitTokenCap)
    }

    /// With no samples, the run keeps the thermal state snapshotted at init
    /// rather than overwriting it with nothing.
    @Test func completeKeepsInitialThermalStateWhenNoSamplesExist() {
        var session = makeSession()
        let before = session.thermalStateAtStart
        let stats = InferenceStats(
            totalTokens: 10, promptTokens: 2, completionTokens: 8,
            totalDuration: 1, promptEvalDuration: 0.1, evalDuration: 0.9,
            loadDuration: 0, contextLength: 10
        )
        session.complete(
            with: stats,
            response: "ok",
            thermalSummary: BenchmarkSample.computeThermalSummary(from: [])
        )
        #expect(session.thermalStateAtStart == before)
        #expect(session.thermalNonNominalFraction == nil)
    }

    // MARK: - Export

    @Test func csvHeaderCarriesTheRunConditionColumns() {
        let csv = ExportService.exportSessionsToCSV([])
        let header = csv.split(separator: "\n").first.map(String.init) ?? ""
        for column in [
            "max_tokens_requested", "finish_reason", "hit_token_cap",
            "temperature", "top_p", "seed",
            "thermal_state_at_start", "thermal_non_nominal_fraction",
        ] {
            #expect(header.contains(column), "missing column: \(column)")
        }
    }

    @Test func csvRowMatchesHeaderWidth() {
        var session = makeSession()
        session.recordRequestParameters(
            maxTokens: 512, temperature: 0.7, topP: 0.9, seed: 42
        )
        session.finishReason = "length"
        session.thermalStateAtStart = 0
        session.thermalNonNominalFraction = 0.25

        let csv = ExportService.exportSessionsToCSV([session])
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)

        // The prompt is the last column and is escaped; a plain prompt keeps
        // the row a straight comma split, so widths must agree.
        let headerCount = lines[0].split(separator: ",", omittingEmptySubsequences: false).count
        let rowCount = lines[1].split(separator: ",", omittingEmptySubsequences: false).count
        #expect(headerCount == rowCount)

        #expect(lines[1].contains("length"))
        #expect(lines[1].contains("true"))   // hit_token_cap
        #expect(lines[1].contains("512"))
    }

    @Test func csvLeavesTokenCapBlankWhenTheBackendReportedNoFinishReason() {
        let session = makeSession()
        let csv = ExportService.exportSessionsToCSV([session])
        // No finish_reason means we cannot claim the cap was or wasn't hit.
        #expect(!csv.contains("false"))
        #expect(!csv.contains("true"))
    }

    // MARK: - Helpers

    private func makeSession() -> BenchmarkSession {
        BenchmarkSession(
            modelId: "test-model",
            modelName: "Test Model",
            backend: .openai,
            prompt: "hello"
        )
    }
}
