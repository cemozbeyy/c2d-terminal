import C2DCore
import SwiftUI

/// Number formatting shared by the popover and the panel so the same figure reads the same everywhere.
enum TokenSaverFormat {
    static func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
    static func reduction(_ percent: Double?) -> String { percent.map { "−\(Int($0.rounded()))%" } ?? "—" }
    static func sizes(_ before: Int, _ after: Int) -> String { "\(bytes(before)) → \(bytes(after))" }
    static func period(_ r: ClosedRange<Date>) -> String {
        "\(r.lowerBound.formatted(date: .abbreviated, time: .omitted)) – \(r.upperBound.formatted(date: .abbreviated, time: .omitted))"
    }
    static func event(_ e: OptimizationRecord) -> String {
        var parts = [e.createdAt.formatted(date: .abbreviated, time: .shortened), e.stage?.label ?? "", e.mode?.rawValue ?? ""]
        if let b = e.originalBytes, let a = e.resultBytes { parts.append(sizes(b, a)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Label left, key figure right, one line of basis underneath.
struct MetricRow: View {
    let label: String
    let value: String
    var detail: String?
    var valueMuted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(Theme.Typography.detail).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                Text(value).font(Theme.Typography.body).fontWeight(.semibold).monospacedDigit()
                    .foregroundStyle(valueMuted ? Theme.textMuted : Theme.textPrimary)
            }
            if let detail {
                Text(detail).font(Theme.Typography.metadata).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The three kinds of number Token Saver has, never added together: verified savings (none yet), estimated
/// reduction (recorded local events), provider-reported usage (transcripts).
struct TokenSaverMetricsView: View {
    let summary: TokenSaverSummary
    /// Shown instead of the usage figure when the ledger has none (off, not read, unavailable + reason).
    let usageNote: String
    /// Popover: hides the empty estimate row and adds the latest event; the panel lists events on its own.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            MetricRow(label: "Verified savings", value: "Not measured yet",
                      detail: "Verified only by a controlled comparison of provider-reported usage.", valueMuted: true)
            estimate
            usage
            if compact {
                if let e = summary.latest {
                    MetricRow(label: "Latest activity", value: "\(TokenSaverFormat.reduction(reduction(e))) bytes", detail: TokenSaverFormat.event(e))
                } else {
                    Text("No optimization recorded yet.").font(Theme.Typography.metadata).foregroundStyle(Theme.textMuted)
                }
            }
        }
    }

    @ViewBuilder private var estimate: some View {
        if let t = summary.handedOff ?? summary.prepared {
            let handedOff = summary.handedOff != nil
            MetricRow(label: "Estimated reduction", value: "\(TokenSaverFormat.reduction(t.byteReductionPercent)) bytes",
                      detail: "\(TokenSaverFormat.sizes(t.originalBytes, t.resultBytes)) measured · ~\(t.estimatedTokenReduction.formatted()) tokens (heuristic) · "
                        + (handedOff ? "\(t.count) hand-off\(t.count == 1 ? "" : "s")" : "\(t.count) prepared, none handed off"))
        } else if !compact {
            MetricRow(label: "Estimated reduction", value: "None recorded",
                      detail: "Each Optimize run below and each hand-off of its result is recorded with measured sizes.", valueMuted: true)
        }
    }

    @ViewBuilder private var usage: some View {
        if let u = summary.usage {
            let scope = "\(summary.usageSessions) session\(summary.usageSessions == 1 ? "" : "s")" + (summary.usagePeriod.map { " · \(TokenSaverFormat.period($0))" } ?? "")
            MetricRow(label: "Provider-reported usage", value: u.total.formatted(),
                      detail: compact ? "\(scope) · usage, not savings"
                                      : "\(scope) · input \(u.inputTokens.formatted()) · output \(u.outputTokens.formatted()) · cache read \(u.cacheReadInputTokens.formatted()) · cache write \(u.cacheCreationInputTokens.formatted()) · usage, not savings")
        } else {
            MetricRow(label: "Provider-reported usage", value: "—", detail: usageNote, valueMuted: true)
        }
    }

    private func reduction(_ e: OptimizationRecord) -> Double? {
        guard let b = e.originalBytes, let a = e.resultBytes, b > 0 else { return nil }
        return Double(b - a) / Double(b) * 100
    }
}
