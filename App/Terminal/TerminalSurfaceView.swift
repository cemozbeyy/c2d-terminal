import AppKit
import SwiftTerm
import SwiftUI

/// Hosts SwiftTerm's `TerminalView` for one panel controller. The delegate is set before the
/// first real frame so the initial grid reaches the PTY (spike finding: no `sizeChanged` otherwise).
/// Editor-style line editing in the keys the shell already understands (zsh emacs keymap):
/// Option+←/→ (with or without Shift) jump words as ESC b / ESC f — SwiftTerm's own `CSI 1;3D` is
/// unbound in zsh; Cmd+Backspace clears the line (^U); Ctrl-C goes through `interrupt()` so a second
/// press at an idle prompt ends the shell. Installed as a local event monitor because SwiftTerm's
/// `keyDown` is not overridable; the monitor only acts while this view is the first responder.
@MainActor
private func handleEditingKey(_ event: NSEvent, view: TerminalView, controller: TerminalPanelController) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let key = event.charactersIgnoringModifiers?.unicodeScalars.first.map { Int($0.value) }
    if flags.contains(.option), !flags.contains(.command), !flags.contains(.control) {
        if key == NSLeftArrowFunctionKey { controller.disarmInterrupt(); view.send([0x1b, UInt8(ascii: "b")]); return true }
        if key == NSRightArrowFunctionKey { controller.disarmInterrupt(); view.send([0x1b, UInt8(ascii: "f")]); return true }
    }
    if flags == .command, key == 0x7f { controller.disarmInterrupt(); view.send([0x15]); return true }
    if flags == .control, event.charactersIgnoringModifiers == "c", controller.interrupt() { return true }
    controller.disarmInterrupt()
    return false
}

/// SwiftTerm's `TerminalView` does not take keyboard focus when clicked (its `mouseDown` never calls
/// `makeFirstResponder`, unlike the editor's text view), so a freshly shown terminal could not be
/// typed into until something else happened to focus it. Grabbing focus on click fixes that. (`keyDown`
/// is not `open`, so the editing shortcuts stay in the local monitor; `mouseDown` is.)
final class FocusableTerminalView: TerminalView {
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }
}

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
        let view = FocusableTerminalView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), font: nil,
                                         options: TerminalOptions(scrollback: Self.effectiveScrollbackLines))
        view.terminalDelegate = controller
        let controller = controller
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            guard let view, event.window?.firstResponder === view else { return event }
            return handleEditingKey(event, view: view, controller: controller) ? nil : event
        }
        view.nativeBackgroundColor = NSColor(hex: 0x0B0E16)
        view.nativeForegroundColor = NSColor(hex: 0xE8EAF1)
        view.caretColor = NSColor(hex: 0x7C6CF0)
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        // Cmd-click opens detected file paths and URLs (Bible Part 5 §7.3). Detection runs on hover/click,
        // never on the output stream, so it adds no cost to rendering.
        view.linkReporting = .implicit
        view.linkHighlightMode = .hoverWithModifier
        controller.attach(view)
        // A terminal that was just shown (New Session, or a restored panel) takes keyboard focus so the
        // user can type without clicking first. Deferred: the view has no window yet inside makeNSView.
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window, window.isKeyWindow else { return }
            if !(window.firstResponder is NSText || window.firstResponder is TerminalView) {
                window.makeFirstResponder(view)
            }
        }
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    final class Coordinator { var monitor: Any? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        // Detach happens through the controller when the panel closes; a hidden panel keeps its session.
        if let m = coordinator.monitor { NSEvent.removeMonitor(m); coordinator.monitor = nil }
    }
}
