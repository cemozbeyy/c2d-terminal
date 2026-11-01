import AppKit
import Foundation

/// Small regex highlighter for the languages the MVP claims (Bible Part 5 §4.3). It is honest
/// about scope: keywords, strings, comments, numbers, type and function names, markup tags and
/// attributes. No LSP, no semantic coloring. Colours come from the active theme (`Palette`).
struct SyntaxHighlighter {
    struct Language {
        let name: String
        let keywords: Set<String>
        let lineComment: String?
        let blockComment: (String, String)?
        let stringDelimiters: [Character]
        /// Object-notation languages (JSON/YAML): a string immediately before a `:` is a property key,
        /// coloured apart from string values the way editors like VS Code do.
        var highlightsKeys: Bool = false
        /// Markdown uses its own set of passes (headings, emphasis, code, links, lists) instead of the
        /// keyword/string/comment model.
        var isMarkdown: Bool = false
        /// HTML/XML-like: tags, attributes and their values instead of keywords.
        var isMarkup: Bool = false
        /// JavaScript/TypeScript: JSX tags and attributes are coloured like markup.
        var hasJSX: Bool = false
        /// Lower-case names (variables, properties, labels) get their own colour, as VS Code's Dark+ does.
        /// Off where bare words are data or commands (Shell, JSON, YAML).
        var colorsVariables: Bool = true
    }

    static let languages: [String: Language] = {
        let swift = Language(name: "Swift", keywords: ["import", "let", "var", "func", "struct", "class", "enum", "protocol", "extension", "if", "else", "guard", "return", "for", "in", "while", "switch", "case", "default", "break", "continue", "throw", "throws", "try", "catch", "async", "await", "actor", "public", "private", "internal", "fileprivate", "static", "self", "Self", "nil", "true", "false", "init", "deinit", "where", "some", "any", "mutating", "override", "final", "defer", "do", "typealias", "associatedtype", "inout", "is", "as", "super", "open"], lineComment: "//", blockComment: ("/*", "*/"), stringDelimiters: ["\""])
        var js = Language(name: "JavaScript", keywords: ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "new", "this", "class", "extends", "import", "export", "from", "async", "await", "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "null", "undefined", "true", "false", "interface", "type", "enum", "implements", "readonly", "public", "private", "protected", "static", "as", "yield", "delete", "void"], lineComment: "//", blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'", "`"])
        js.hasJSX = true
        let html = Language(name: "HTML", keywords: [], lineComment: nil, blockComment: ("<!--", "-->"), stringDelimiters: [], isMarkup: true)
        let py = Language(name: "Python", keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "import", "from", "as", "try", "except", "finally", "raise", "with", "lambda", "yield", "pass", "break", "continue", "None", "True", "False", "async", "await", "global", "nonlocal", "del", "is", "assert"], lineComment: "#", blockComment: nil, stringDelimiters: ["\"", "'"])
        let sh = Language(name: "Shell", keywords: ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "in", "function", "return", "export", "local", "echo", "exit", "source", "set", "unset", "readonly"], lineComment: "#", blockComment: nil, stringDelimiters: ["\"", "'"], colorsVariables: false)
        let json = Language(name: "JSON", keywords: ["true", "false", "null"], lineComment: nil, blockComment: nil, stringDelimiters: ["\""], highlightsKeys: true, colorsVariables: false)
        let md = Language(name: "Markdown", keywords: [], lineComment: nil, blockComment: nil, stringDelimiters: [], isMarkdown: true)
        let yaml = Language(name: "YAML", keywords: ["true", "false", "null"], lineComment: "#", blockComment: nil, stringDelimiters: ["\"", "'"], highlightsKeys: true, colorsVariables: false)
        let c = Language(name: "C", keywords: ["int", "char", "void", "return", "if", "else", "for", "while", "struct", "typedef", "static", "const", "include", "define", "switch", "case", "break", "continue", "unsigned", "long", "double", "float", "sizeof", "enum", "extern", "goto", "do", "default"], lineComment: "//", blockComment: ("/*", "*/"), stringDelimiters: ["\""])
        let rust = Language(name: "Rust", keywords: ["fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "for", "in", "if", "else", "match", "while", "loop", "return", "use", "mod", "crate", "self", "Self", "as", "where", "async", "await", "move", "ref", "const", "static", "type", "unsafe", "dyn", "true", "false", "break", "continue"], lineComment: "//", blockComment: ("/*", "*/"), stringDelimiters: ["\""])
        let go = Language(name: "Go", keywords: ["package", "import", "func", "var", "const", "type", "struct", "interface", "map", "chan", "if", "else", "for", "range", "switch", "case", "default", "return", "go", "defer", "select", "break", "continue", "fallthrough", "nil", "true", "false"], lineComment: "//", blockComment: ("/*", "*/"), stringDelimiters: ["\"", "`"])
        return ["swift": swift, "js": js, "jsx": js, "ts": js, "tsx": js, "mjs": js, "cjs": js, "py": py, "sh": sh, "zsh": sh, "bash": sh,
                "json": json, "jsonc": json, "json5": json, "storekit": json, "geojson": json, "webmanifest": json,
                "md": md, "markdown": md, "mdown": md, "markdn": md, "mkd": md, "txt": md, "text": md, "log": md,
                "html": html, "htm": html, "xml": html, "svg": html, "plist": html, "xib": html, "storyboard": html, "vue": html,
                "yml": yaml, "yaml": yaml, "c": c, "h": c, "m": c, "cpp": c, "hpp": c, "rs": rust, "go": go]
    }()

    static func language(for ext: String) -> Language? { languages[ext] }

    /// Files above this size are shown without highlighting (Bible Part 5 §4.5).
    static let maximumHighlightedLength = 300_000

    /// One colour per token kind. Each Marketplace theme carries its own (`ThemeDescriptor.syntax`).
    struct Palette: @unchecked Sendable {
        var keyword: NSColor
        var string: NSColor
        var comment: NSColor
        var number: NSColor
        var propertyKey: NSColor
        var link: NSColor
        var plain: NSColor
        var type: NSColor
        var function: NSColor
        var tag: NSColor
        var attribute: NSColor
        var punctuation: NSColor
        /// Bracket pair colours by nesting depth (VS Code's bracket pair colorization defaults).
        var brackets: [NSColor] = [NSColor(hex: 0xFFD700), NSColor(hex: 0xDA70D6), NSColor(hex: 0x179FFF)]

        private static func c(_ hex: UInt32) -> NSColor { NSColor(hex: hex) }

        /// VS Code "Dark+" with violet keywords, for Midnight Violet.
        static let midnight = Palette(keyword: c(0xC586C0), string: c(0xCE9178), comment: c(0x6A9955), number: c(0xB5CEA8),
                                      propertyKey: c(0x9CDCFE), link: c(0x4FC1FF), plain: c(0xE2E4EC), type: c(0x4EC9B0),
                                      function: c(0xDCDCAA), tag: c(0x569CD6), attribute: c(0x9CDCFE), punctuation: c(0x8B90A3))
        /// Night Owl–style cool tones, for Ocean.
        static let ocean = Palette(keyword: c(0xC792EA), string: c(0xECC48D), comment: c(0x6C8B91), number: c(0xF78C6C),
                                   propertyKey: c(0x7FDBCA), link: c(0x82AAFF), plain: c(0xD6DEEB), type: c(0xFFCB8B),
                                   function: c(0x82AAFF), tag: c(0x7FDBCA), attribute: c(0xADDB67), punctuation: c(0x7E95A0))
        /// Gruvbox-style warm tones, for Ember.
        static let ember = Palette(keyword: c(0xFB4934), string: c(0xB8BB26), comment: c(0x928374), number: c(0xD3869B),
                                   propertyKey: c(0x83A598), link: c(0x83A598), plain: c(0xEBDBB2), type: c(0xFABD2F),
                                   function: c(0x8EC07C), tag: c(0xFE8019), attribute: c(0xFABD2F), punctuation: c(0xA89984))
        /// VS Code "Light+", for Daylight.
        static let daylight = Palette(keyword: c(0x0000FF), string: c(0xA31515), comment: c(0x008000), number: c(0x098658),
                                      propertyKey: c(0x0451A5), link: c(0x0070C1), plain: c(0x1F1F1F), type: c(0x267F99),
                                      function: c(0x795E26), tag: c(0x800000), attribute: c(0xE50000), punctuation: c(0x6B6F7A),
                                      brackets: [c(0x0431FA), c(0x319331), c(0x7B3814)])
    }

    let language: Language
    var palette = Palette.midnight

    /// A matched bracket pair: UTF-16 offsets of the opening and closing bracket, and nesting depth.
    struct BracketPair: Sendable { let open: Int, close: Int, depth: Int }

    /// Applies foreground colors to the whole storage. Cheap enough for the size limit above.
    /// Returns the bracket pairs found outside strings and comments (empty where brackets are not coloured).
    @discardableResult
    func highlight(_ storage: NSTextStorage) -> [BracketPair] {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: full)
        storage.addAttribute(.foregroundColor, value: palette.plain, range: full)
        guard text.length <= Self.maximumHighlightedLength else { storage.endEditing(); return [] }

        if language.isMarkdown { highlightMarkdown(storage, full: full); storage.endEditing(); return [] }
        if language.isMarkup { highlightMarkup(storage, full: full); storage.endEditing(); return [] }

        // Names first, so keywords (`if (`, `return`) and strings override them below.
        if language.colorsVariables {
            color(storage, "\\b[a-z_][A-Za-z0-9_]*\\b", palette.propertyKey, in: full)            // variables, properties
        }
        color(storage, "\\b[A-Z][A-Za-z0-9_]*\\b", palette.type, in: full)                       // Types, Constants
        color(storage, "\\b([A-Za-z_][A-Za-z0-9_]*)(?=\\s*\\()", palette.function, group: 1, in: full)  // calls(
        if language.hasJSX {
            color(storage, "\\b(string|number|boolean|any|unknown|never|object|symbol|bigint)\\b", palette.type, in: full)  // TS primitives
            // `<Tag` / `</tag` where `<` follows no word, `)` or `]` (so `a < b` and `Array<T>` stay plain),
            // and attribute names directly followed by `={`, `="` or `='`.
            color(storage, "(?<![\\w)\\]])</?([A-Za-z][\\w.]*)(?=[\\s>/])", palette.tag, group: 1, in: full)
            color(storage, "(?<=\\s)([A-Za-z_][\\w-]*)(?==[{\"'])", palette.attribute, group: 1, in: full)
        }
        color(storage, "[@#][A-Za-z_][A-Za-z0-9_]*\\b", palette.keyword, in: full)                // @attributes, #macros, #include
        if !language.keywords.isEmpty {
            let pattern = "\\b(" + language.keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")\\b"
            if let re = try? NSRegularExpression(pattern: pattern) {
                for m in re.matches(in: storage.string, range: full) { storage.addAttribute(.foregroundColor, value: palette.keyword, range: m.range) }
            }
        }
        if let re = try? NSRegularExpression(pattern: "\\b\\d+(\\.\\d+)?\\b") {
            for m in re.matches(in: storage.string, range: full) { storage.addAttribute(.foregroundColor, value: palette.number, range: m.range) }
        }
        for d in language.stringDelimiters {
            let q = NSRegularExpression.escapedPattern(for: String(d))
            if let re = try? NSRegularExpression(pattern: "\(q)(?:\\\\.|[^\(q)\\\\\\n])*\(q)") {
                for m in re.matches(in: storage.string, range: full) { storage.addAttribute(.foregroundColor, value: palette.string, range: m.range) }
            }
        }
        // Property keys (a string just before a `:`) are recoloured apart from string values, so an
        // object reads key/value like it does in VS Code. Runs after strings so it overrides them.
        // JSON keys are always quoted — matching only quoted keys avoids false hits like `http` in a
        // `"http://…"` value. YAML keys may be bare, but only at the start of a line.
        if language.highlightsKeys {
            if let re = try? NSRegularExpression(pattern: "(\"(?:\\\\.|[^\"\\\\\\n])*\")\\s*:") {
                for m in re.matches(in: storage.string, range: full) { storage.addAttribute(.foregroundColor, value: palette.propertyKey, range: m.range(at: 1)) }
            }
            if language.name == "YAML", let re = try? NSRegularExpression(pattern: "^\\s*([A-Za-z_][\\w-]*)\\s*:", options: .anchorsMatchLines) {
                for m in re.matches(in: storage.string, range: full) { storage.addAttribute(.foregroundColor, value: palette.propertyKey, range: m.range(at: 1)) }
            }
        }
        if let lc = language.lineComment, let re = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: lc) + ".*$", options: .anchorsMatchLines) {
            for m in re.matches(in: storage.string, range: full) { storage.addAttribute(.foregroundColor, value: palette.comment, range: m.range) }
        }
        if let (open, close) = language.blockComment, let re = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: open) + "[\\s\\S]*?" + NSRegularExpression.escapedPattern(for: close)) {
            for m in re.matches(in: storage.string, range: full) { storage.addAttribute(.foregroundColor, value: palette.comment, range: m.range) }
        }
        let pairs = colorBrackets(storage)
        storage.endEditing()
        return pairs
    }

    /// Pair colours by depth. Runs last and skips brackets already coloured as string or comment, so
    /// an unbalanced `(` inside a literal does not shift every pair after it.
    private func colorBrackets(_ storage: NSTextStorage) -> [BracketPair] {
        let skip = [palette.string, palette.comment]
        var depth = 0
        var stack: [Int] = []
        var pairs: [BracketPair] = []
        for (i, u) in storage.string.utf16.enumerated() {
            let opens = u == 0x28 || u == 0x5B || u == 0x7B      // ( [ {
            guard opens || u == 0x29 || u == 0x5D || u == 0x7D else { continue }
            if let fg = storage.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor, skip.contains(fg) { continue }
            if !opens { depth = max(0, depth - 1) }
            storage.addAttribute(.foregroundColor, value: palette.brackets[depth % palette.brackets.count], range: NSRange(location: i, length: 1))
            if opens { depth += 1; stack.append(i) } else if let open = stack.popLast() { pairs.append(BracketPair(open: open, close: i, depth: depth)) }
        }
        return pairs
    }

    private func color(_ storage: NSTextStorage, _ pattern: String, _ color: NSColor, group: Int = 0,
                       options: NSRegularExpression.Options = [], in range: NSRange) {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        for m in re.matches(in: storage.string, range: range) where m.range(at: group).location != NSNotFound {
            storage.addAttribute(.foregroundColor, value: color, range: m.range(at: group))
        }
    }

    /// HTML/XML (also the HTML inside Markdown): every `<…>` region gets its brackets, tag name,
    /// attribute names and quoted values coloured; text between tags stays plain. Comments last.
    private func highlightMarkup(_ storage: NSTextStorage, full: NSRange) {
        guard let region = try? NSRegularExpression(pattern: "</?[A-Za-z!?][^<>]*>") else { return }
        for r in region.matches(in: storage.string, range: full).map(\.range) {
            color(storage, "</?|/?>|\\?>|=", palette.punctuation, in: r)
            color(storage, "^</?[!?]?([A-Za-z][\\w:.-]*)", palette.tag, group: 1, in: r)
            color(storage, "\\s([A-Za-z_:@][\\w:.-]*)", palette.attribute, group: 1, in: r)
            color(storage, "\"[^\"]*\"|'[^']*'", palette.string, in: r)
        }
        color(storage, "<!--[\\s\\S]*?-->", palette.comment, in: full)
    }

    /// Markdown passes, applied in an order where later overrides win where they should (code beats
    /// emphasis; headings/lists set the line, inline spans refine it). Only syntax that is present gets
    /// colour, so prose and plain `.txt`/`.log` files stay readable.
    private func highlightMarkdown(_ storage: NSTextStorage, full: NSRange) {
        let s = storage.string
        func pass(_ pattern: String, _ color: NSColor, group: Int = 0, options: NSRegularExpression.Options = []) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for m in re.matches(in: s, range: full) where m.range(at: group).location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: color, range: m.range(at: group))
            }
        }
        // Block structure (whole line).
        pass("^\\s{0,3}#{1,6}\\s.*$", palette.keyword, options: .anchorsMatchLines)      // # headings
        pass("^\\s*>\\s?.*$", palette.comment, options: .anchorsMatchLines)              // > blockquote
        pass("^\\s*([-*+]|\\d+[.)])\\s", palette.number, group: 1, options: .anchorsMatchLines)  // list markers
        // Inline spans.
        pass("\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__", palette.number)                        // **bold**
        pass("(?<![\\*\\w])\\*[^*\\n]+\\*(?![\\*\\w])|(?<![_\\w])_[^_\\n]+_(?![_\\w])", palette.string)  // *italic*
        pass("\\[[^\\]\\n]+\\]\\([^)\\n]+\\)", palette.link)                             // [text](url)
        highlightMarkup(storage, full: full)                                              // inline HTML (<p>, <img …>)
        pass("https?://[^\\s)\\]\"']+", palette.link)                                      // bare URL
        // Code last so it wins over emphasis inside it.
        pass("```[\\s\\S]*?```", palette.propertyKey)                                    // ``` fenced block
        pass("`[^`\\n]+`", palette.propertyKey)                                          // `inline code`
    }
}
