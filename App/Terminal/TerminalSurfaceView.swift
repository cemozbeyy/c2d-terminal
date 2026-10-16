import AppKit
import SwiftTerm
import SwiftUI

/// Hosts SwiftTerm's `TerminalView` for one panel controller. The delegate is set before the
/// first real frame so the initial grid reaches the PTY (spike finding: no `sizeChanged` otherwise).
struct TerminalSurfaceView: NSViewRepresentable {
    let controller: TerminalPanelController

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
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
