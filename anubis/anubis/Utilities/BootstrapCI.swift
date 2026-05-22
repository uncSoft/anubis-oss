//
//  BootstrapCI.swift
//  anubis
//
//  Compute the 95% bootstrap confidence interval of the mean for a
//  small sample. Used by BenchmarkRunGroup to summarise N repetitions
//  as `mean ± CI` instead of a single number that hides variance.
//
//  Why bootstrap rather than Student's t-interval:
//   - No normality assumption. Benchmark distributions (tok/s, J/Tok,
//     etc.) are usually skewed in practice — thermal warmup, cache
//     effects, and sampler variance all distort the tail.
//   - More honest with small N (default N=5). Student's t can
//     under-state the width on small skewed samples; bootstrap gets
//     the right coverage without requiring you to verify normality
//     per-metric.
//   - Cheap. 1000 resamples × N=5 = 5000 sums per metric — vanishing
//     cost relative to running the benchmarks themselves.
//
//  Reference: Efron & Tibshirani (1993); Reproducible LLM Evaluation
//  (arXiv 2410.03492) uses bootstrap CIs throughout.
//

import Foundation

struct BootstrapCI {
    /// Number of bootstrap resamples. 1000 is the conventional default
    /// — gives stable CI bounds for the 2.5th / 97.5th percentiles.
    static let resamples = 1000

    /// 95% bootstrap CI bounds for the *mean* of the supplied sample.
    ///
    /// Returns (low, high). Both are nil if the sample has fewer than
    /// two finite, non-nil values — a single point has no CI.
    ///
    /// The seed is exposed for tests; production callers omit it and
    /// the resamples use the system random number generator.
    static func confidenceInterval95(
        _ sample: [Double],
        seed: UInt64? = nil
    ) -> (low: Double, high: Double)? {
        let cleaned = sample.filter { $0.isFinite }
        guard cleaned.count >= 2 else { return nil }

        var rng: any RandomNumberGenerator = seed.map { SeededRNG(seed: $0) } ?? SystemRandomNumberGenerator()

        var bootstrapMeans = [Double]()
        bootstrapMeans.reserveCapacity(resamples)

        let n = cleaned.count
        for _ in 0..<resamples {
            var sum = 0.0
            for _ in 0..<n {
                let idx = Int.random(in: 0..<n, using: &rng)
                sum += cleaned[idx]
            }
            bootstrapMeans.append(sum / Double(n))
        }

        bootstrapMeans.sort()
        let lowIdx = Int((0.025 * Double(resamples)).rounded(.down))
        let highIdx = Int((0.975 * Double(resamples)).rounded(.up)) - 1
        return (
            low: bootstrapMeans[max(0, lowIdx)],
            high: bootstrapMeans[min(resamples - 1, highIdx)]
        )
    }

    /// Sample mean of finite values; nil if all values are nil/NaN.
    static func mean(_ sample: [Double]) -> Double? {
        let cleaned = sample.filter { $0.isFinite }
        guard !cleaned.isEmpty else { return nil }
        return cleaned.reduce(0, +) / Double(cleaned.count)
    }

    /// Sample standard deviation (Bessel-corrected, n-1 in the
    /// denominator). nil if fewer than two finite values.
    static func stdev(_ sample: [Double]) -> Double? {
        let cleaned = sample.filter { $0.isFinite }
        guard cleaned.count >= 2, let mu = mean(cleaned) else { return nil }
        let sumSquares = cleaned.reduce(0.0) { acc, x in acc + (x - mu) * (x - mu) }
        return (sumSquares / Double(cleaned.count - 1)).squareRoot()
    }
}

/// Deterministic RNG seedable for tests. Uses splitmix64 — fast,
/// well-distributed, no external dependency.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
