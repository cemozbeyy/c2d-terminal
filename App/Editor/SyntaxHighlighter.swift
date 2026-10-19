import AppKit
import Foundation

/// Small regex highlighter for the languages the MVP claims (Bible Part 5 §4.3). It is honest
/// about scope: keywords, strings, comments, numbers. No LSP, no semantic coloring.
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
    }

    static let languages: [String: Language] = {
        let swift = Language(name: "Swift", keywords: ["import", "let", "var", "func", "struct", "class", "enum", "protocol", "extension", "if", "else", "guard", "return", "for", "in", "while", "switch", "case", "default", "break", "continue", "throw", "throws", "try", "catch", "async", "await", "actor", "public", "private", "internal", "fileprivate", "static", "self", "Self", "nil", "true", "false", "init", "deinit", "where", "some", "any", "mutating", "override", "final", "defer", "do", "typealias", "associatedtype", "inout", "is", "as", "super", "open"], lineComment: "//", blockComment: ("/*", "*/"), stringDelimiters: ["\""])
        let js = Language(name: "JavaScript", keywords: ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "new", "this", "class", "extends", "import", "export", "from", "async", "await", "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "null", "undefined", "true", "false", "interface", "type", "enum", "implements", "readonly", "public", "private", "protected", "static", "as", "yield", "delete", "void"], lineComment: "//", blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'", "`"])
        let py = Language(name: "Python", keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "import", "from", "as", "try", "except", "finally", "raise", "with", "lambda", "yield", "pass", "break", "continue", "None", "True", "False", "async", "await", "global", "nonlocal", "del", "is", "assert"], lineComment: "#", blockComment: nil, stringDelimiters: ["\"", "'"])
        let sh = Language(name: "Shell", keywords: ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "in", "function", "return", "export", "local", "echo", "exit", "source", "set", "unset", "readonly"], lineComment: "#", blockComment: nil, stringDelimiters: ["\"", "'"])
        let json = Language(name: "JSON", keywords: ["true", "false", "null"], lineComment: nil, blockComment: nil, stringDelimiters: ["\""], highlightsKeys: true)
        let md = Language(name: "Markdown", keywords: [], lineComment: nil, blockComment: nil, stringDelimiters: [], isMarkdown: true)
        let yaml = Language(name: "YAML", keywords: ["true", "false", "null"], lineComment: "#", blockComment: nil, stringDelimiters: ["\"", "'"], highlightsKeys: true)
        let c = Language(name: "C", keywords: ["int", "char", "void", "return", "if", "else", "for", "while", "struct", "typedef", "static", "const", "include", "define", "switch", "case", "break", "continue", "unsigned", "long", "double", "float", "sizeof", "enum", "extern", "goto", "do", "default"], lineComment: "//", blockComment: ("/*", "*/"), stringDelimiters: ["\""])
        let rust = Language(name: "Rust", keywords: ["fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "for", "in", "if", "else", "match", "while", "loop", "return", "use", "mod", "crate", "self", "Self", "as", "where", "async", "await", "move", "ref", "const", "static", "type", "unsafe", "dyn", "true", "false", "break", "continue"], lineComment: "//", blockComment: ("/*", "*/"), stringDelimiters: ["\""])
        let go = Language(name: "Go", keywords: ["package", "import", "func", "var", "const", "type", "struct", "interface", "map", "chan", "if", "else", "for", "range", "switch", "case", "default", "return", "go", "defer", "select", "break", "continue", "fallthrough", "nil", "true", "false"], lineComment: "//", blockComment: ("/*", "*/"), stringDelimiters: ["\"", "`"])
        return ["swift": swift, "js": js, "jsx": js, "ts": js, "tsx": js, "mjs": js, "cjs": js, "py": py, "sh": sh, "zsh": sh, "bash": sh,
                "json": json, "jsonc": json, "json5": json, "storekit": json, "geojson": json, "webmanifest": json,
                "md": md, "markdown": md, "mdown": md, "markdn": md, "mkd": md, "txt": md, "text": md, "log": md,
                "yml": yaml, "yaml": yaml, "c": c, "h": c, "m": c, "cpp": c, "hpp": c, "rs": rust, "go": go]
    }()

    static func language(for ext: String) -> Language? { languages[ext] }

    /// Files above this size are shown without highlighting (Bible Part 5 §4.5).
    static let maximumHighlightedLength = 300_000

    struct Palette {
        var keyword = NSColor.systemPurple
        var string = NSColor.systemRed
        var comment = NSColor.systemGreen
        var number = NSColor.systemOrange
        var propertyKey = NSColor.systemTeal
        var link = NSColor.systemBlue
        var plain = NSColor.textColor
    }

    let language: Language
    var palette = Palette()

    /// Applies foreground colors to the whole storage. Cheap enough for the size limit above.
    func highlight(_ storage: NSTextStorage) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: full)
        storage.addAttribute(.foregroundColor, value: palette.plain, range: full)
        guard text.length <= Self.maximumHighlightedLength else { storage.endEditing(); return }

        if language.isMarkdown { highlightMarkdown(storage, full: full); storage.endEditing(); return }

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
        storage.endEditing()
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
        pass("https?://[^\\s)\\]]+", palette.link)                                       // bare URL
        // Code last so it wins over emphasis inside it.
        pass("```[\\s\\S]*?```", palette.propertyKey)                                    // ``` fenced block
        pass("`[^`\\n]+`", palette.propertyKey)                                          // `inline code`
    }
}
