import C2DCore
import SwiftUI

/// Number formatting for the Token Saver popover.
enum TokenSaverFormat {
    /// 107 280 767 → "107.3M": a popover column is too narrow for full counts.
    static func count(_ n: Int) -> String { n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
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
