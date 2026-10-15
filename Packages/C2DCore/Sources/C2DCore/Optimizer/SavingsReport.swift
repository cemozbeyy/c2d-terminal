import Foundation

/// A before/after comparison that refuses to claim what it cannot support (Bible Part 10 §14).
public struct SavingsReport: Hashable, Sendable {
    public let baselineTokens: Int
    public let optimizedTokens: Int
    public let source: MeasurementSource
    public let optimizerCostTokens: Int
    /// nil when the baseline is zero or the two measurements come from different sources.
    public let reductionPercent: Double?
    /// Baseline minus optimized minus the optimizer's own cost; negative means it did not pay off.
    public var netReduction: Int { baselineTokens - optimizedTokens - optimizerCostTokens }
    public let label: String

    public static func make(baseline: TokenEstimate, optimized: TokenEstimate, optimizerCost: Int = 0) -> SavingsReport {
        let sameSource = baseline.source == optimized.source
        let percent: Double? = (baseline.tokens > 0 && sameSource) ? Double(baseline.tokens - optimized.tokens) / Double(baseline.tokens) * 100 : nil
        let source: MeasurementSource = sameSource ? baseline.source : .unavailable
        let label: String
        if !sameSource {
            label = "Not comparable: baseline is \(baseline.source.label), optimized is \(optimized.source.label)"
        } else if baseline.tokens == 0 {
            label = "No baseline (0 tokens); nothing to compare"
        } else {
            let pct = Int(percent!.rounded())
            let noun = source == .providerConfirmed ? "Confirmed" : "Estimated"
            let qualifier = source == .providerConfirmed ? "provider-confirmed" : "\(source.label); not provider-confirmed"
            let net = baseline.tokens - optimized.tokens - optimizerCost
            let direction = pct >= 0 ? "reduction" : "increase"
            label = "\(noun) input \(direction) \(abs(pct))% (\(qualifier))" + (optimizerCost > 0 ? "; net \(net) tokens after optimizer cost" : "")
        }
        return SavingsReport(baselineTokens: baseline.tokens, optimizedTokens: optimized.tokens, source: source,
                             optimizerCostTokens: optimizerCost, reductionPercent: percent, label: label)
    }
}
