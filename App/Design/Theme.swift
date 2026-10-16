import AppKit
import SwiftUI

/// Semantic design tokens (Bible Part 12 §3): components consume these, never raw hex values.
/// Dark-first (§5.1: deep charcoal/navy, restrained violet accent); light values are provided so
/// the system appearance still works, but the product is designed and verified dark-first.
enum Theme {
    // MARK: Surfaces
    static let window = dynamic(dark: 0x0C0E14, light: 0xF4F5F8)
    static let rail = dynamic(dark: 0x0F121A, light: 0xECEEF3)
    static let panel = dynamic(dark: 0x151925, light: 0xFFFFFF)
    static let panelHeader = dynamic(dark: 0x1A1F2E, light: 0xF1F2F6)
    static let elevated = dynamic(dark: 0x1F2436, light: 0xFFFFFF)
    static let terminalBackground = dynamic(dark: 0x0B0E16, light: 0x1B1F2B)
    static let field = dynamic(dark: 0x11141D, light: 0xFFFFFF)

    // MARK: Lines
    static let borderSubtle = dynamic(dark: 0x262B3B, light: 0xD9DCE5)
    static let borderStrong = dynamic(dark: 0x343A4F, light: 0xBFC4D2)

    // MARK: Text
    static let textPrimary = dynamic(dark: 0xE8EAF1, light: 0x171A22)
    static let textSecondary = dynamic(dark: 0xA3A8B8, light: 0x5A6070)
    static let textMuted = dynamic(dark: 0x6B7186, light: 0x8A90A0)

    // MARK: Accent and states (never the only signal for a state — §4.4)
    static let accent = dynamic(dark: 0x7C6CF0, light: 0x5B4BE0)
    static let accentSoft = dynamic(dark: 0x2A2650, light: 0xE6E2FF)
    static let success = dynamic(dark: 0x3DD68C, light: 0x1F9D5B)
    static let warning = dynamic(dark: 0xF5B84B, light: 0xB8771A)
    static let error = dynamic(dark: 0xF26B6B, light: 0xC43B3B)
    static let info = dynamic(dark: 0x5DA9F6, light: 0x2F6FD3)
    /// Foreground placed on top of an accent/state fill (e.g. drop-zone label); always light.
    static let onAccent = Color.white
    /// Dimming scrim behind modal overlays (the palette). Alpha is applied at the call site.
    static let scrim = Color.black

    // MARK: Typography (§3) — one token per distinct size/design; weight stays at the call site so
    // every migration is a 1:1 swap with no appearance change. Monospaced tokens keep code aligned.
    enum Typography {
        static let heading = Font.headline
        static let title2 = Font.system(size: 13)
        static let body = Font.system(size: 12)
        static let caption = Font.caption
        static let caption2 = Font.caption2
        static let detail = Font.system(size: 11)
        static let badge = Font.system(size: 10.5)
        static let metadata = Font.system(size: 10)
        static let micro = Font.system(size: 9)
        static let mono = Font.system(size: 12, design: .monospaced)
        static let monoBody = Font.system(.caption, design: .monospaced)
        static let monoDetail = Font.system(size: 11, design: .monospaced)
        static let monoMetadata = Font.system(size: 10, design: .monospaced)
        static let monoMicro = Font.system(size: 9, design: .monospaced)
    }

    // MARK: Geometry (§6)
    static let panelRadius: CGFloat = 10
    static let controlRadius: CGFloat = 6
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16

    static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Small rounded status chip; icon + text so color is never the only signal.
struct StatusChip: View {
    let text: String
    var color: Color = Theme.textSecondary
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// Icon tile used for agents/providers in headers and cards.
struct IconTile: View {
    let symbol: String
    var tint: Color = Theme.accent
    var size: CGFloat = 22
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint, in: RoundedRectangle(cornerRadius: size * 0.28))
    }
}

struct PanelCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).stroke(Theme.borderSubtle))
            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
    }
}

extension View {
    func panelCard() -> some View { modifier(PanelCard()) }
}

extension PanelKindStyle {
    static func style(for kind: String) -> PanelKindStyle {
        switch kind {
        case "terminal": PanelKindStyle(symbol: "terminal", tint: Theme.success)
        case "editor": PanelKindStyle(symbol: "chevron.left.forwardslash.chevron.right", tint: Theme.info)
        case "projectExplorer": PanelKindStyle(symbol: "folder", tint: Theme.warning)
        case "gitChanges": PanelKindStyle(symbol: "arrow.triangle.branch", tint: Theme.warning)
        case "agentSession": PanelKindStyle(symbol: "cpu", tint: Theme.accent)
        case "tasks": PanelKindStyle(symbol: "checklist", tint: Theme.accent)
        case "tokenOptimizer": PanelKindStyle(symbol: "gauge.with.dots.needle.33percent", tint: Theme.accent)
        default: PanelKindStyle(symbol: "square.dashed", tint: Theme.textMuted)
        }
    }
}

struct PanelKindStyle {
    let symbol: String
    let tint: Color
}
