import SwiftUI

/// Marketplace — for now, a local gallery of built-in themes the user can apply instantly.
/// (No backend: these three ship with the app. A real online catalog is a later, separate feature.)
struct MarketplaceView: View {
    @State private var manager = ThemeManager.shared

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Marketplace").font(.title2).bold()
                    Text("Themes — tap Apply to switch instantly. More categories later.")
                        .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                }
                Text("THEMES").font(Theme.Typography.metadata).fontWeight(.semibold).foregroundStyle(Theme.textMuted)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(manager.themes) { theme in
                        ThemeCard(theme: theme, isActive: theme.id == manager.selectedID) { manager.apply(theme.id) }
                    }
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ThemeCard: View {
    let theme: ThemeDescriptor
    let isActive: Bool
    let apply: () -> Void

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 10) {
            // A little live preview of the theme's own surfaces/accent.
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8).fill(p.window)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Circle().fill(p.accent).frame(width: 9, height: 9)
                        RoundedRectangle(cornerRadius: 3).fill(p.panel).frame(width: 70, height: 9)
                        Spacer()
                    }
                    RoundedRectangle(cornerRadius: 4).fill(p.panelHeader).frame(height: 10)
                    HStack(spacing: 4) {
                        ForEach([p.success, p.warning, p.error, p.info], id: \.self) { Circle().fill($0).frame(width: 7, height: 7) }
                        Spacer()
                        RoundedRectangle(cornerRadius: 3).fill(p.accentSoft).frame(width: 36, height: 8)
                    }
                    Text("Aa").font(Theme.Typography.caption).foregroundStyle(p.textPrimary)
                }
                .padding(10)
            }
            .frame(height: 96)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.borderSubtle))

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(theme.name).font(Theme.Typography.body).fontWeight(.semibold).foregroundStyle(Theme.textPrimary)
                    Text(theme.tagline).font(Theme.Typography.metadata).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer()
                if isActive {
                    Label("Active", systemImage: "checkmark.circle.fill").font(Theme.Typography.caption).foregroundStyle(Theme.success).labelStyle(.titleAndIcon)
                } else {
                    Button("Apply", action: apply).buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            Text("by \(theme.author)").font(Theme.Typography.micro).foregroundStyle(Theme.textMuted)
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).stroke(isActive ? Theme.accent : Theme.borderSubtle, lineWidth: isActive ? 1.5 : 1))
    }
}
