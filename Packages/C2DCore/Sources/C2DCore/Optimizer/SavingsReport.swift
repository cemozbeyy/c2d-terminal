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

/// What Token Saver can say about one project, in three separate kinds that are never added together:
/// provider-reported usage (transcripts), estimated reduction (recorded local events: bytes measured, tokens
/// heuristic), and verified token savings (a controlled comparison of provider-reported usage).
public struct TokenSaverSummary: Hashable, Sendable {
    /// Always nil: nothing in C2D has run a controlled comparison yet (TSD-03), so the UI says "Not measured yet".
    /// Never derived from byte reductions or from usage totals.
    public var verifiedSavedTokens: Int? { nil }
    /// Events whose result left C2D (copied or written). nil when there is none — shown as "none recorded", not 0.
    public let handedOff: EventTotals?
    /// Optimize runs whose result was only shown in the panel.
    public let prepared: EventTotals?
    /// The newest recorded event with measured bytes.
    public let latest: OptimizationRecord?
    /// Provider-reported usage, or nil when the ledger is unavailable / not read. Usage, never savings.
    public let usage: ProviderUsage?
    public let usageSessions: Int
    public let usagePeriod: ClosedRange<Date>?

    public init(eventTotals: [OptimizationStage: EventTotals], history: [OptimizationRecord], ledger: TranscriptLedgerResult?) {
        let handOff = OptimizationStage.allCases.filter(\.isHandOff).compactMap { eventTotals[$0] }
        handedOff = handOff.isEmpty ? nil : handOff.dropFirst().reduce(handOff[0]) {
            EventTotals(count: $0.count + $1.count, originalBytes: $0.originalBytes + $1.originalBytes, resultBytes: $0.resultBytes + $1.resultBytes,
                        originalTokens: $0.originalTokens + $1.originalTokens, resultTokens: $0.resultTokens + $1.resultTokens)
        }
        prepared = eventTotals[.prepared]
        latest = history.filter { $0.stage != nil && $0.originalBytes != nil }.max { $0.createdAt < $1.createdAt }
        if case .available(let l)? = ledger {
            usage = l.total; usageSessions = l.sessions.count
            let first = l.sessions.compactMap(\.firstTimestamp).min(), last = l.sessions.compactMap(\.lastTimestamp).max()
            usagePeriod = first.flatMap { f in last.map { f...max(f, $0) } }
        } else {
            usage = nil; usageSessions = 0; usagePeriod = nil
        }
    }
}
