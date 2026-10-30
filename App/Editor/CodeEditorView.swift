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

        let textView = CodeTextView(frame: .zero)
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
        textView.font = CodeTextView.codeFont
        textView.textContainerInset = NSSize(width: 10, height: 8)
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
        context.coordinator.scrollView = scroll
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
        // Reading the theme here makes SwiftUI call this again when it changes; recolour in place.
        if context.coordinator.themeID != ThemeManager.shared.selectedID { context.coordinator.applyHighlighting() }
        // External reload or tab switch: push model text into the view only when they differ.
        if tv.string != tab.text {
            let sel = tv.selectedRange()
            tv.string = tab.text
            tv.setSelectedRange(NSRange(location: min(sel.location, (tab.text as NSString).length), length: 0))
            context.coordinator.applyHighlighting()
            container.gutter.needsDisplay = true
        }
        if let line = tab.pendingLine {
            let ns = tv.string as NSString
            var location = 0, current = 1
            while current < line, location < ns.length {
                let r = ns.range(of: "\n", range: NSRange(location: location, length: ns.length - location))
                guard r.location != NSNotFound else { break }
                location = r.location + 1; current += 1
            }
            // Offset into the line for the column, clamped to the line's end.
            if let col = tab.pendingColumn, col > 1 {
                let lineEnd = ns.range(of: "\n", range: NSRange(location: location, length: ns.length - location)).location
                let maxLoc = lineEnd == NSNotFound ? ns.length : lineEnd
                location = min(location + (col - 1), maxLoc)
            }
            tv.setSelectedRange(NSRange(location: location, length: 0))
            tv.scrollRangeToVisible(NSRange(location: location, length: 0))
            tv.window?.makeFirstResponder(tv)
            Task { @MainActor in tab.pendingLine = nil; tab.pendingColumn = nil }   // clear outside the view update
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let tab: EditorTab
        weak var textView: CodeTextView?
        weak var scrollView: NSScrollView?
        weak var gutter: LineNumberGutterView?
        private var highlightTask: Task<Void, Never>?
        private let highlighter: SyntaxHighlighter?
        /// The theme the text was last coloured with.
        private(set) var themeID = ""

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
            tv.needsDisplay = true      // current-line band
            gutter?.needsDisplay = true // active line number
        }

        func applyHighlighting() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let sel = tv.selectedRange()
            let theme = ThemeManager.shared.selected
            themeID = theme.id
            let background = NSColor(theme.palette.panel)
            scrollView?.backgroundColor = background
            tv.backgroundColor = background
            tv.insertionPointColor = theme.syntax.plain
            tv.currentLineColor = theme.syntax.plain.withAlphaComponent(0.05)
            tv.guideColor = theme.syntax.plain.withAlphaComponent(0.14)
            tv.indentUnit = CodeTextView.indentUnit(of: tv.string)
            gutter?.background = background
            gutter?.number = NSColor(theme.palette.textMuted)
            gutter?.activeNumber = theme.syntax.plain
            gutter?.needsDisplay = true
            if var highlighter {
                highlighter.palette = theme.syntax
                tv.bracketPairs = highlighter.highlight(storage)
                tv.bracketColors = theme.syntax.brackets
            } else {
                storage.addAttribute(.foregroundColor, value: theme.syntax.plain, range: NSRange(location: 0, length: storage.length))
            }
            let full = NSRange(location: 0, length: storage.length)
            storage.addAttributes([.font: CodeTextView.codeFont, .paragraphStyle: CodeTextView.paragraphStyle], range: full)
            tv.defaultParagraphStyle = CodeTextView.paragraphStyle
            tv.typingAttributes = [.font: CodeTextView.codeFont, .paragraphStyle: CodeTextView.paragraphStyle, .foregroundColor: theme.syntax.plain]
            tv.setSelectedRange(sel)
        }
    }
}

/// Gutter + scroll view side by side. Plain views only; no rulers, no visual effects.
final class EditorContainerView: NSView {
    let scrollView: NSScrollView
    let gutter: LineNumberGutterView
    static let gutterWidth: CGFloat = 44

    init(scrollView: NSScrollView, textView: CodeTextView) {
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
    var background = NSColor.controlBackgroundColor
    var number = NSColor.tertiaryLabelColor
    var activeNumber = NSColor.labelColor

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSText.didChangeNotification, object: textView)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    @objc private func redraw() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let text = tv.string as NSString
        let visible = tv.visibleRect
        let inset = tv.textContainerInset.height
        let caret = tv.selectedRange().location

        func draw(_ line: Int, in fragment: NSRect, active: Bool) {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: active ? activeNumber : number]
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attrs)
            // The fragment includes the line spacing below the text; centre on the text part only.
            let y = fragment.minY - visible.minY + inset + (fragment.height - CodeTextView.lineSpacing - size.height) / 2
            label.draw(at: NSPoint(x: bounds.width - size.width - 8, y: y), withAttributes: attrs)
        }

        guard text.length > 0 else { draw(1, in: lm.extraLineFragmentRect, active: true); return }
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
            let next = NSMaxRange(lineRange)
            let active = NSLocationInRange(caret, lineRange) || (caret == text.length && next == text.length && !text.hasSuffix("\n"))
            draw(line, in: lm.lineFragmentRect(forGlyphAt: min(glyph, max(lm.numberOfGlyphs - 1, 0)), effectiveRange: nil), active: active)
            if next >= text.length {
                if text.hasSuffix("\n") { draw(line + 1, in: lm.extraLineFragmentRect, active: caret == text.length) }
                break
            }
            if next > stopAt { break }
            charIndex = next
            line += 1
        }
    }
}

/// The text surface, with the VS Code reading aids painted behind the glyphs: a current-line band
/// and indent guides. Font and line height are fixed here so gutter and text stay aligned.
final class CodeTextView: NSTextView {
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// 12pt SF Mono + 4 ≈ VS Code's 18pt line height.
    static let lineSpacing: CGFloat = 4
    static let charWidth = ("0" as NSString).size(withAttributes: [.font: codeFont]).width
    static let paragraphStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineSpacing
        p.tabStops = []
        p.defaultTabInterval = charWidth * 4
        return p
    }()

    var currentLineColor = NSColor.clear
    var guideColor = NSColor.clear
    /// Columns per indent level; guides are drawn every `indentUnit` columns.
    var indentUnit = 4
    /// From the last highlight pass; may lag an edit by the highlight debounce, so offsets are bounds-checked.
    var bracketPairs: [SyntaxHighlighter.BracketPair] = []
    var bracketColors: [NSColor] = []

    /// Smallest leading-space run of 2+ in the first lines (ignoring 1-space ` * ` doc lines); tabs count as 4.
    static func indentUnit(of text: String) -> Int {
        var unit = Int.max
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(2000) {
            if line.first == "\t" { return 4 }
            let n = line.prefix { $0 == " " }.count
            if n >= 2, n < line.count { unit = min(unit, n) }
        }
        return unit == Int.max ? 4 : min(unit, 8)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer else { return }
        let text = string as NSString
        let origin = textContainerOrigin

        let sel = selectedRange()
        if sel.length == 0 {
            let frag = text.length == 0 || (sel.location >= text.length && text.hasSuffix("\n"))
                ? lm.extraLineFragmentRect
                : lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: min(sel.location, text.length - 1)), effectiveRange: nil)
            currentLineColor.setFill()
            NSRect(x: 0, y: frag.minY + origin.y, width: bounds.width, height: frag.height).fill()
        }

        guard text.length > 0 else { return }
        guideColor.setFill()
        let chars = lm.characterRange(forGlyphRange: lm.glyphRange(forBoundingRect: rect, in: tc), actualGlyphRange: nil)
        var loc = text.lineRange(for: NSRange(location: min(chars.location, text.length - 1), length: 0)).location
        while loc < text.length, loc <= NSMaxRange(chars) {
            let line = text.lineRange(for: NSRange(location: loc, length: 0))
            let levels = guideColumns(line, text) / indentUnit
            if levels > 0 {
                let frag = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: line.location), effectiveRange: nil)
                for i in 0..<levels {
                    let x = origin.x + tc.lineFragmentPadding + CGFloat(i * indentUnit) * Self.charWidth
                    NSRect(x: x.rounded(), y: frag.minY + origin.y, width: 1, height: frag.height).fill()
                }
            }
            loc = NSMaxRange(line)
        }
        drawActiveBracketPair(sel, text, lm, tc, origin)
    }

    /// VS Code's bracket-pair guide and bracket match: a guide in the pair's colour down the innermost
    /// multi-line block around the caret, and boxes around a bracket next to the caret and its partner.
    private func drawActiveBracketPair(_ sel: NSRange, _ text: NSString, _ lm: NSLayoutManager, _ tc: NSTextContainer, _ origin: NSPoint) {
        guard sel.length == 0, !bracketColors.isEmpty else { return }
        let caret = sel.location
        let valid = bracketPairs.filter { $0.close < text.length }
        func lineRange(_ i: Int) -> NSRange { text.lineRange(for: NSRange(location: i, length: 0)) }
        func color(_ p: SyntaxHighlighter.BracketPair) -> NSColor { bracketColors[p.depth % bracketColors.count] }

        // Innermost pair spanning lines with the caret inside (just before the closer counts as inside).
        if let block = valid.filter({ $0.open < caret && caret <= $0.close && lineRange($0.open).location != lineRange($0.close).location })
                            .max(by: { $0.open < $1.open }) {
            let openLine = lineRange(block.open), closeLine = lineRange(block.close)
            let cols = min(indent(openLine, text) ?? 0, indent(closeLine, text) ?? 0)
            let x = (origin.x + tc.lineFragmentPadding + CGFloat(cols) * Self.charWidth).rounded()
            let top = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: NSMaxRange(openLine)), effectiveRange: nil).minY
            let bottom = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: closeLine.location), effectiveRange: nil).minY
            if bottom > top {
                color(block).setFill()
                NSRect(x: x, y: top + origin.y, width: 1, height: bottom - top).fill()
            }
        }

        // Bracket match: the bracket before the caret wins (right after typing `)`), then the one after it.
        let touching = [caret - 1, caret].lazy.compactMap { i in valid.first { $0.open == i || $0.close == i } }.first
        if let pair = touching {
            for i in [pair.open, pair.close] {
                var r = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: NSRange(location: i, length: 1), actualCharacterRange: nil), in: tc)
                r.size.height -= Self.lineSpacing
                r = r.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -0.5, dy: 0.5)
                color(pair).withAlphaComponent(0.15).setFill()
                r.fill()
                guideColor.withAlphaComponent(0.5).setStroke()
                let path = NSBezierPath(rect: r)
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    /// Leading indent in columns, or nil for a blank line.
    private func indent(_ line: NSRange, _ text: NSString) -> Int? {
        var cols = 0
        for i in line.location..<NSMaxRange(line) {
            switch text.character(at: i) {
            case 0x20: cols += 1
            case 0x09: cols += 4
            case 0x0A, 0x0D: return nil
            default: return cols
            }
        }
        return nil
    }

    /// A blank line carries the smaller indent of its nearest non-blank neighbours, so guides run
    /// through empty lines inside a block and stop at its end.
    private func guideColumns(_ line: NSRange, _ text: NSString) -> Int {
        if let own = indent(line, text) { return own }
        func neighbour(_ forward: Bool) -> Int {
            var r = line
            for _ in 0..<200 {
                if forward { guard NSMaxRange(r) < text.length else { return 0 }; r = text.lineRange(for: NSRange(location: NSMaxRange(r), length: 0)) }
                else { guard r.location > 0 else { return 0 }; r = text.lineRange(for: NSRange(location: r.location - 1, length: 0)) }
                if let n = indent(r, text) { return n }
            }
            return 0
        }
        return min(neighbour(false), neighbour(true))
    }
}
