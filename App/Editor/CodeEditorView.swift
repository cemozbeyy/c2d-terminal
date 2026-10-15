import AppKit
import C2DCore
import SwiftUI

/// NSTextView-based code surface (ADR-014): native undo/redo, find bar, selection, IME.
/// Line numbers come from a sibling gutter view, not `NSRulerView`: on macOS 26 the ruler's
/// scroll-pocket backdrop stops SwiftUI from compositing the rest of the window.
struct CodeEditorView: NSViewRepresentable {
    let tab: EditorTab

    func makeCoordinator() -> Coordinator { Coordinator(tab: tab) }

    func makeNSView(context: Context) -> EditorContainerView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let textView = NSTextView(frame: .zero)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.string = tab.text
        scroll.documentView = textView

        let container = EditorContainerView(scrollView: scroll, textView: textView)
        context.coordinator.textView = textView
        context.coordinator.gutter = container.gutter
        context.coordinator.applyHighlighting()
        return container
    }

    /// Without this SwiftUI asks the view for its fitting size, which the unbounded text
    /// container reports as enormous, and the whole window layout overflows.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditorContainerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 300, height: 200))
    }

    func updateNSView(_ container: EditorContainerView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        // External reload or tab switch: push model text into the view only when they differ.
        if tv.string != tab.text {
            let sel = tv.selectedRange()
            tv.string = tab.text
            tv.setSelectedRange(NSRange(location: min(sel.location, (tab.text as NSString).length), length: 0))
            context.coordinator.applyHighlighting()
            container.gutter.needsDisplay = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let tab: EditorTab
        weak var textView: NSTextView?
        weak var gutter: LineNumberGutterView?
        private var highlightTask: Task<Void, Never>?
        private let highlighter: SyntaxHighlighter?

        init(tab: EditorTab) {
            self.tab = tab
            self.highlighter = SyntaxHighlighter.language(for: tab.document.languageHint).map { SyntaxHighlighter(language: $0) }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            tab.update(text: tv.string)
            gutter?.needsDisplay = true
            highlightTask?.cancel()
            highlightTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                self?.applyHighlighting()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            let loc = min(tv.selectedRange().location, ns.length)
            let before = ns.substring(to: loc)
            let line = before.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) } + 1
            let col = loc - (before.lastIndex(of: "\n").map { before.distance(from: before.startIndex, to: $0) + 1 } ?? 0) + 1
            tab.cursorLine = line
            tab.cursorColumn = col
        }

        func applyHighlighting() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let sel = tv.selectedRange()
            if let highlighter {
                highlighter.highlight(storage)
            } else {
                storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: NSRange(location: 0, length: storage.length))
            }
            storage.addAttribute(.font, value: tv.font ?? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular), range: NSRange(location: 0, length: storage.length))
            tv.setSelectedRange(sel)
        }
    }
}

/// Gutter + scroll view side by side. Plain views only; no rulers, no visual effects.
final class EditorContainerView: NSView {
    let scrollView: NSScrollView
    let gutter: LineNumberGutterView
    static let gutterWidth: CGFloat = 44

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.scrollView = scrollView
        self.gutter = LineNumberGutterView(textView: textView)
        super.init(frame: .zero)
        addSubview(gutter)
        addSubview(scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    required init?(coder: NSCoder) { nil }

    @objc private func scrolled() { gutter.needsDisplay = true }

    override func layout() {
        super.layout()
        gutter.frame = NSRect(x: 0, y: 0, width: Self.gutterWidth, height: bounds.height)
        scrollView.frame = NSRect(x: Self.gutterWidth, y: 0, width: max(0, bounds.width - Self.gutterWidth), height: bounds.height)
        gutter.needsDisplay = true
    }
}

/// Draws the line number of every visible line fragment, aligned with the text view.
final class LineNumberGutterView: NSView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSText.didChangeNotification, object: textView)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    @objc private func redraw() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let text = tv.string as NSString
        let visible = tv.visibleRect
        let inset = tv.textContainerInset.height

        func draw(_ line: Int, in fragment: NSRect) {
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attrs)
            let y = fragment.minY - visible.minY + inset + (fragment.height - size.height) / 2
            label.draw(at: NSPoint(x: bounds.width - size.width - 6, y: y), withAttributes: attrs)
        }

        guard text.length > 0 else { draw(1, in: lm.extraLineFragmentRect); return }
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        let visibleChars = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        var charIndex = text.lineRange(for: NSRange(location: min(visibleChars.location, text.length), length: 0)).location
        var line = text.substring(to: charIndex).components(separatedBy: "\n").count
        let stopAt = NSMaxRange(visibleChars)

        // Each iteration advances to the next line start; the last line (with or without a trailing
        // newline) terminates the loop explicitly, so a file without a final newline cannot spin.
        while charIndex <= text.length {
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyph = lm.glyphIndexForCharacter(at: lineRange.location)
            draw(line, in: lm.lineFragmentRect(forGlyphAt: min(glyph, max(lm.numberOfGlyphs - 1, 0)), effectiveRange: nil))
            let next = NSMaxRange(lineRange)
            if next >= text.length {
                if text.hasSuffix("\n") { draw(line + 1, in: lm.extraLineFragmentRect) }
                break
            }
            if next > stopAt { break }
            charIndex = next
            line += 1
        }
    }
}
