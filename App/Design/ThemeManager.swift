import AppKit
import SwiftUI

/// A full set of semantic color tokens. Themes are dark-first (the app forces dark); a theme swaps
/// every surface/text/accent color at once. Geometry and typography are not themed.
struct ThemePalette: Sendable, Hashable {
    var window, rail, panel, panelHeader, elevated, terminalBackground, field: Color
    var borderSubtle, borderStrong: Color
    var textPrimary, textSecondary, textMuted: Color
    var accent, accentSoft, success, warning, error, info: Color
}

/// A selectable theme shown in the Marketplace.
struct ThemeDescriptor: Identifiable, Sendable {
    let id: String
    let name: String
    let tagline: String
    let author: String
    let palette: ThemePalette
    /// Drives the window's `colorScheme` so AppKit controls (scrollbars, menus) match. Dark by default.
    var isDark: Bool = true
}

private func c(_ hex: UInt32) -> Color { Color(nsColor: NSColor(hex: hex)) }

extension ThemeDescriptor {
    /// The original dark charcoal + violet accent (Bible §5.1) — the default.
    static let midnight = ThemeDescriptor(
        id: "midnight", name: "Midnight Violet", tagline: "Deep charcoal, restrained violet accent", author: "C2D",
        palette: ThemePalette(
            window: c(0x0C0E14), rail: c(0x0F121A), panel: c(0x151925), panelHeader: c(0x1A1F2E),
            elevated: c(0x1F2436), terminalBackground: c(0x0B0E16), field: c(0x11141D),
            borderSubtle: c(0x262B3B), borderStrong: c(0x343A4F),
            textPrimary: c(0xE8EAF1), textSecondary: c(0xA3A8B8), textMuted: c(0x6B7186),
            accent: c(0x7C6CF0), accentSoft: c(0x2A2650), success: c(0x3DD68C), warning: c(0xF5B84B), error: c(0xF26B6B), info: c(0x5DA9F6)))

    /// Cool blue-charcoal with a teal accent.
    static let ocean = ThemeDescriptor(
        id: "ocean", name: "Ocean", tagline: "Cool blue-charcoal, teal accent", author: "C2D",
        palette: ThemePalette(
            window: c(0x0A0F14), rail: c(0x0C1218), panel: c(0x111A22), panelHeader: c(0x15212B),
            elevated: c(0x1A2832), terminalBackground: c(0x080D12), field: c(0x0E161D),
            borderSubtle: c(0x223038), borderStrong: c(0x30424D),
            textPrimary: c(0xE6EEF2), textSecondary: c(0x9DB0BA), textMuted: c(0x647781),
            accent: c(0x2FBCC9), accentSoft: c(0x123038), success: c(0x3DD68C), warning: c(0xF0B44A), error: c(0xF06B6B), info: c(0x4FB0E0)))

    /// Warm charcoal with an amber accent.
    static let ember = ThemeDescriptor(
        id: "ember", name: "Ember", tagline: "Warm charcoal, amber accent", author: "C2D",
        palette: ThemePalette(
            window: c(0x12100E), rail: c(0x17130F), panel: c(0x201A15), panelHeader: c(0x29211A),
            elevated: c(0x332920), terminalBackground: c(0x0E0C0A), field: c(0x1A1511),
            borderSubtle: c(0x382E24), borderStrong: c(0x4D3F30),
            textPrimary: c(0xF2ECE4), textSecondary: c(0xBEB2A1), textMuted: c(0x8A7E6C),
            accent: c(0xEB9A3E), accentSoft: c(0x3A2817), success: c(0x8AC24A), warning: c(0xF0B44A), error: c(0xF0685B), info: c(0xCE954F)))

    /// Light mode: white surfaces, dark text, the brand violet. The terminal surface stays dark
    /// (SwiftTerm colors are set in `TerminalSurfaceView`; theming it is tracked separately).
    static let daylight = ThemeDescriptor(
        id: "daylight", name: "Daylight", tagline: "White surfaces, violet accent", author: "C2D",
        palette: ThemePalette(
            window: c(0xF3F4F7), rail: c(0xE9EBF0), panel: c(0xFFFFFF), panelHeader: c(0xEEF0F4),
            elevated: c(0xF7F8FA), terminalBackground: c(0x0B0E16), field: c(0xFFFFFF),
            borderSubtle: c(0xDDE0E7), borderStrong: c(0xC4C9D4),
            textPrimary: c(0x1A1D26), textSecondary: c(0x4A4F5E), textMuted: c(0x858B9A),
            accent: c(0x6C5CE0), accentSoft: c(0xE6E3FA), success: c(0x1F9D63), warning: c(0xB7791F), error: c(0xD64545), info: c(0x2B7DD6)),
        isDark: false)
}

/// Holds the active theme and applies a new one at runtime. `Theme`'s color tokens read
/// `ThemeManager.shared.current`, so SwiftUI's Observation re-renders every view that uses a color
/// token when `selectedID` changes — no per-call-site changes needed.
@Observable
final class ThemeManager {
    nonisolated(unsafe) static let shared = ThemeManager()
    let themes: [ThemeDescriptor] = [.midnight, .ocean, .ember, .daylight]
    private(set) var selectedID: String
    private static let key = "c2dThemeID"
    private static let lastDarkKey = "c2dLastDarkThemeID"

    var current: ThemePalette { themes.first { $0.id == selectedID }?.palette ?? themes[0].palette }
    var selected: ThemeDescriptor { themes.first { $0.id == selectedID } ?? themes[0] }

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.key)
        selectedID = (saved.flatMap { id in [ThemeDescriptor.midnight, .ocean, .ember, .daylight].first { $0.id == id } }?.id) ?? "midnight"
    }

    var isDark: Bool { selected.isDark }

    func apply(_ id: String) {
        guard let theme = themes.first(where: { $0.id == id }) else { return }
        selectedID = id
        UserDefaults.standard.set(id, forKey: Self.key)
        if theme.isDark { UserDefaults.standard.set(id, forKey: Self.lastDarkKey) }
    }

    /// Top-bar sun/moon toggle: switch to Daylight, or back to the last dark theme chosen.
    func toggleLightDark() {
        if isDark {
            apply(ThemeDescriptor.daylight.id)
        } else {
            let lastDark = UserDefaults.standard.string(forKey: Self.lastDarkKey)
            apply(lastDark.flatMap { id in themes.first { $0.id == id && $0.isDark }?.id } ?? ThemeDescriptor.midnight.id)
        }
    }
}
