//
//  anubisTests.swift
//  anubisTests
//
//  Created by J T on 1/25/26.
//

import Foundation
import Testing
@testable import anubis

struct anubisTests {

    @Test func mtplxDefaultConfiguration() {
        let config = BackendConfiguration.defaultMTPLX

        #expect(config.name == "MTPLX")
        #expect(config.type == .openaiCompatible)
        #expect(config.baseURL == "http://localhost:8000")
        #expect(config.isEnabled)
        #expect(BackendConfiguration.defaultIDs.contains(config.id))
    }

    @Test @MainActor func mtplxServerTimingDecoding() throws {
        let json = #"""
        {
            "elapsed_s": 2.75,
            "request_elapsed_s": 2.9,
            "prompt_eval_time_s": 0.4,
            "prompt_tps": 125.5,
            "ttft_s": 0.45,
            "decode_elapsed_s": 2.35,
            "decode_tok_s": 54.25
        }
        """#
        let data = try #require(json.data(using: .utf8))

        let stats = try JSONDecoder().decode(MTPLXStats.self, from: data)

        #expect(stats.requestElapsed == 2.9)
        #expect(stats.promptEvalTime == 0.4)
        #expect(stats.promptTokensPerSecond == 125.5)
        #expect(stats.timeToFirstToken == 0.45)
        #expect(stats.decodeElapsed == 2.35)
        #expect(stats.decodeTokensPerSecond == 54.25)
        #expect(stats.hasServerTiming)
    }

}
