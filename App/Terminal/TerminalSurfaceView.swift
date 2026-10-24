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

    /// During a live window drag SwiftTerm 1.99 queues each size for its render loop instead of resizing the
    /// grid synchronously (`queueSizeChange`), and nothing reconciles at the end of the drag. Re-applying the
    /// final frame once the drag is over takes the synchronous path (`inLiveResize` is false now), so the grid
    /// — and through `sizeChanged`, the PTY — always ends at the settled size. A no-op when already consistent.
    #if DEBUG
    /// `-c2dResizeCheck` moves the window programmatically, which never sets `inLiveResize`; this flag makes the
    /// view take SwiftTerm's live-drag path (queued size changes) so the check covers what a pointer drag does.
    var simulatedLiveResize = false
    override var inLiveResize: Bool { simulatedLiveResize || super.inLiveResize }
    #endif

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.inLiveResize else { return }
            self.setFrameSize(self.frame.size)
            debugTrace("live resize ended: view=\(Int(self.frame.width))x\(Int(self.frame.height)) container=\(Int(self.superview?.frame.width ?? 0))x\(Int(self.superview?.frame.height ?? 0))")
        }
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

    /// SwiftUI owns this throwaway container; the panel-owned `TerminalView` is moved into it as a
    /// subview and survives tab switches, so its scrollback and current screen are never lost (and the
    /// terminal is never blanked when a sibling tab is closed). Returning a cached NSView straight from
    /// `makeNSView` is unsafe; re-parenting a persistent subview between fresh containers is the robust
    /// way to keep an AppKit view alive across SwiftUI view-identity changes.
    /// The terminal always fills its container: `layout()` re-applies `bounds` on every AppKit layout pass, so
    /// the frame can never lag behind a window or divider drag or a re-parenting into a container that had no
    /// size yet. Autoresizing masks alone left the hosted view at a stale width (owner report 2026-10-23: text
    /// cut off at the width of an earlier, narrower pane after the window grew back).
    final class Container: NSView {
        override func layout() {
            super.layout()
            for v in subviews where v.frame != bounds { v.frame = bounds }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let container = Container()
        let term = controller.hostedView ?? makeTerminal()
        term.frame = container.bounds
        if term.superview !== container { term.removeFromSuperview(); container.addSubview(term) }
        container.needsLayout = true
        DispatchQueue.main.async { [weak term] in
            guard let term, let window = term.window, window.isKeyWindow else { return }
            if !(window.firstResponder is NSText || window.firstResponder is TerminalView) {
                window.makeFirstResponder(term)
            }
        }
        return container
    }

    private func makeTerminal() -> FocusableTerminalView {
        // `cols`/`rows` in the options are recomputed from the frame; only `scrollback` matters here.
        let fresh = FocusableTerminalView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), font: nil,
                                          options: TerminalOptions(scrollback: Self.effectiveScrollbackLines))
        fresh.terminalDelegate = controller
        let controller = controller
        controller.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak fresh] event in
            guard let fresh, event.window?.firstResponder === fresh else { return event }
            return handleEditingKey(event, view: fresh, controller: controller) ? nil : event
        }
        fresh.nativeBackgroundColor = NSColor(hex: 0x0B0E16)
        fresh.nativeForegroundColor = NSColor(hex: 0xE8EAF1)
        fresh.caretColor = NSColor(hex: 0x7C6CF0)
        fresh.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        // Cmd-click opens detected file paths and URLs (Bible Part 5 §7.3). Detection runs on hover/click,
        // never on the output stream, so it adds no cost to rendering.
        fresh.linkReporting = .implicit
        fresh.linkHighlightMode = .hoverWithModifier
        controller.hostedView = fresh
        controller.attach(fresh)
        return fresh
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        // Tab switch: lift the persistent terminal out of the dying container so it survives for the
        // next tab (the controller still owns it). It is released in `detach()` when the panel closes.
        container.subviews.compactMap { $0 as? TerminalView }.forEach { $0.removeFromSuperview() }
    }
}
