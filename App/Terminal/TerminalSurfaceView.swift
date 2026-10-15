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
        view.nativeBackgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1)
        view.nativeForegroundColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        controller.attach(view)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: TerminalView, coordinator: ()) {
        // Detach happens through the controller when the panel closes; a hidden panel keeps its session.
    }
}
