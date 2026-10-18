import AppKit
import SwiftTerm
import SwiftUI

/// Hosts SwiftTerm's `TerminalView` for one panel controller. The delegate is set before the
/// first real frame so the initial grid reaches the PTY (spike finding: no `sizeChanged` otherwise).
struct TerminalSurfaceView: NSViewRepresentable {
    let controller: TerminalPanelController

    /// Scrollback lines kept per terminal. SwiftTerm's default is 500, which loses a build log; 10 000
    /// is the bound (Bible Part 4 §5.4). Memory stays bounded by this cap — see `docs/PERFORMANCE.md`.
    static let scrollbackLines = 10_000

    /// Debug builds may override the cap (`-c2dScrollbackLines <n>`) so the runtime check can prove the
    /// probe fails at SwiftTerm's default and passes at ours. Release always uses `scrollbackLines`.
    static var effectiveScrollbackLines: Int {
        #if DEBUG
        let override = UserDefaults.standard.integer(forKey: "c2dScrollbackLines")
        if override > 0 { return override }
        #endif
        return scrollbackLines
    }

    func makeNSView(context: Context) -> TerminalView {
        // `cols`/`rows` in the options are recomputed from the frame; only `scrollback` matters here.
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), font: nil,
                                options: TerminalOptions(scrollback: Self.effectiveScrollbackLines))
        view.terminalDelegate = controller
        view.nativeBackgroundColor = NSColor(hex: 0x0B0E16)
        view.nativeForegroundColor = NSColor(hex: 0xE8EAF1)
        view.caretColor = NSColor(hex: 0x7C6CF0)
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        // Cmd-click opens detected file paths and URLs (Bible Part 5 §7.3). Detection runs on hover/click,
        // never on the output stream, so it adds no cost to rendering.
        view.linkReporting = .implicit
        view.linkHighlightMode = .hoverWithModifier
        controller.attach(view)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: TerminalView, coordinator: ()) {
        // Detach happens through the controller when the panel closes; a hidden panel keeps its session.
    }
}
