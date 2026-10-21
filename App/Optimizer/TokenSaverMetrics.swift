import C2DCore
import SwiftUI

/// Number formatting for the Token Saver popover.
enum TokenSaverFormat {
    static func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
    static func sizes(_ before: Int, _ after: Int) -> String { "\(bytes(before)) → \(bytes(after))" }
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
