import Foundation
import Testing
@testable import C2DCore

@Suite struct OutputCondenserTests {
    @Test func emptyAndShortOutputPassThroughUnchanged() {
        let e = OutputCondenser.condense("")
        #expect(e.text == "" && !e.changed && e.linesBefore == 0)
        let s = OutputCondenser.condense("On branch main\nnothing to commit, working tree clean\n")
        #expect(s.text == "On branch main\nnothing to commit, working tree clean" && !s.changed)
    }

    @Test func escapesAndProgressRedrawsAreStripped() {
        let raw = "\u{1B}[1;31merror\u{1B}[0m: bad\n\u{1B}]0;title\u{07}ok\nDownloading 10%\rDownloading 55%\rDownloading 100%\nab\u{08}c\n"
        let c = OutputCondenser.condense(raw)
        #expect(c.text == "error: bad\nok\nDownloading 100%\nac")
        #expect(c.steps == [.strippedEscapes])
    }

    @Test func identicalRunsCollapseButPairsStay() {
        let raw = (["warning: x"] + Array(repeating: "retrying connection to the build server…", count: 40) + ["a", "a", "done"]).joined(separator: "\n")
        let c = OutputCondenser.condense(raw)
        #expect(c.text.contains("retrying connection to the build server…\n[c2d: previous line repeated 39 more times]"))
        #expect(c.text.contains("a\na\ndone"))
        #expect(c.steps.contains(.collapsedRepeats))
    }

    @Test func numericallySimilarRunsFoldButDiagnosticsNeverDo() {
        let compiling = (1...50).map { "Compiling module \($0)/50" }
        let errors = ["Sources/A.swift:12:5: error: x", "Sources/A.swift:57:5: error: x", "Sources/A.swift:90:5: error: x",
                      "Sources/A.swift:91:5: error: x", "Sources/A.swift:92:5: error: x", "Sources/A.swift:93:5: error: x"]
        let c = OutputCondenser.condense((compiling + errors).joined(separator: "\n"))
        #expect(c.text.contains("Compiling module 1/50\nCompiling module 2/50\n[c2d: 47 similar lines omitted (differ only in numbers)]\nCompiling module 50/50"))
        let restored = OutputCondenser.expandGroups(c.text)
        for e in errors { #expect(restored.contains(e)) }
        #expect(c.diagnosticLines == 6)
    }

    @Test func largeOutputKeepsHeadTailAndEveryDiagnosticInTheMiddle() {
        var lines = (0..<2000).map { "line \($0) payload \(String(repeating: "x", count: $0 % 7 + 1))" }   // not digit-only-similar
        lines[1000] = "src/app.ts(41,7): error TS2322: Type 'string' is not assignable to type 'number'."
        lines[1500] = "    at Object.<anonymous> (/repo/test/foo.test.js:88:13)"
        let c = OutputCondenser.condense(lines.joined(separator: "\n"), options: .init(lineBudget: 300, headLines: 40, tailLines: 80))
        #expect(c.steps.contains(.truncatedMiddle))
        #expect(c.text.contains(lines[1000]) && c.text.contains(lines[999]) && c.text.contains(lines[1001]))
        #expect(c.text.contains(lines[1500]))
        #expect(c.text.contains("line 0 payload") && c.text.contains(lines[1999]))
        #expect(c.text.contains("lines omitted]"))
        #expect(c.linesAfter < 140 && c.original == lines.joined(separator: "\n"))
        #expect(c.text.hasPrefix("[c2d: condensed 2000→"))
    }

    @Test func unbudgetedOutputIsNeverTruncated() {
        let raw = (0..<1000).map { "row \($0) \(String(repeating: "y", count: $0 % 5))" }.joined(separator: "\n")
        let c = OutputCondenser.condense(raw, options: .init(lineBudget: nil))
        #expect(!c.steps.contains(.truncatedMiddle))
    }

    @Test func malformedBytesSurviveAsReplacementText() {
        let raw = String(decoding: Data([0x66, 0x6F, 0xFF, 0xFE, 0x0A, 0x6F, 0x6B]), as: UTF8.self)
        let c = OutputCondenser.condense(raw)
        #expect(c.text == raw && !c.changed)
    }

    @Test func grepStyleRunsGroupByFileLosslessly() {
        let raw = ["App/A.swift:10:func a()", "App/A.swift:22:func b()", "App/A.swift:31:    func c()", "App/B.swift:4:func d()", "note: https://x.io:443/p", "12:30:01 started"].joined(separator: "\n")
        let c = OutputCondenser.condense(raw, options: .lossless)
        #expect(c.steps == [.groupedByFile] || c.text == raw)   // never-worse may return the original for tiny inputs
        let many = (1...40).map { "Sources/Big/File.swift:\($0 * 3):    let value\($0) = compute(\($0))" }.joined(separator: "\n")
        let g = OutputCondenser.condense(many, options: .lossless)
        #expect(g.steps == [.groupedByFile] && g.text.utf8.count < many.utf8.count)
        #expect(Array(OutputCondenser.expandGroups(g.text).dropFirst()) == many.split(separator: "\n").map(String.init))
        #expect(OutputCondenser.groupByFile(["https://x.io:443/a", "https://x.io:443/b", "https://x.io:443/c"]) == ["https://x.io:443/a", "https://x.io:443/b", "https://x.io:443/c"])
    }

    @Test func longNonDiagnosticLinesKeepStartAndEnd() {
        let cmd = "    /usr/bin/swiftc " + String(repeating: "-Xflag value ", count: 80) + "-o /tmp/out.o"
        let err = "error: " + String(repeating: "very long diagnostic ", count: 40) + "end"
        let prose = "This paragraph is long prose " + String(repeating: "with many plain words and no flags at all, ", count: 20) + "end."
        let c = OutputCondenser.condense([cmd, err, prose].joined(separator: "\n"))
        #expect(c.text.contains(prose))
        #expect(c.steps.contains(.elidedLongLines) && c.text.contains(err) && c.text.contains("-o /tmp/out.o") && c.text.contains("chars omitted]"))
    }

    @Test func neverWorseThanTheInput() {
        let raw = (1...5).map { "src/f\($0).ts:\($0):1 x" }.joined(separator: "\n")
        let c = OutputCondenser.condense(raw)
        #expect(c.text.utf8.count <= raw.utf8.count)
    }

    @Test func diagnosticClassification() {
        for line in ["error: linker command failed", "FAIL src/a.test.ts", "Test Case '-[X y]' failed (0.1 seconds).", "✘ Test x() failed",
                     "main.swift:3:1: warning: unused", "Traceback (most recent call last):", "npm ERR! code ELIFECYCLE", "zsh: command not found: foo"] {
            #expect(OutputCondenser.isDiagnostic(line), "\(line)")
        }
        for line in ["Compiling C2DCore", "Build complete!", "  12 files changed, 300 insertions(+)", "Downloading 55%"] {
            #expect(!OutputCondenser.isDiagnostic(line), "\(line)")
        }
    }
}

/// Real command outputs in `docs/token-saver/fixtures` (regenerate with `docs/token-saver/make_fixtures.sh`).
/// Always: no diagnostic line may be lost. With `C2D_BENCH_OUT=<file.md>`: writes the benchmark table;
/// with `C2D_CONDENSED_OUT=<dir>`: writes each condensed fixture as `<name>.<mode>.txt`.
@Suite struct OutputCondenserFixtureTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../docs/token-saver/fixtures").standardizedFileURL

    @Test(arguments: [("default", OutputCondenser.Options()), ("lossless", OutputCondenser.Options.lossless)])
    func everyDiagnosticLineSurvivesOnRealOutputs(_ mode: String, _ options: OutputCondenser.Options) throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.fixtures, includingPropertiesForKeys: nil).filter { $0.pathExtension == "txt" }.sorted { $0.path < $1.path }
        try #require(files.count >= 10, "fixtures missing at \(Self.fixtures.path)")
        var rows: [String] = []
        for f in files {
            let raw = String(decoding: try Data(contentsOf: f), as: UTF8.self)
            let clock = ContinuousClock.now
            let c = OutputCondenser.condense(raw, options: options)
            if let dir = ProcessInfo.processInfo.environment["C2D_CONDENSED_OUT"] {   // inputs for docs/token-saver/paired_experiment.py
                try c.text.write(toFile: "\(dir)/\(f.deletingPathExtension().lastPathComponent).\(mode).txt", atomically: true, encoding: .utf8)
            }
            let ms = Double((ContinuousClock.now - clock) / .microseconds(1)) / 1000
            let cleanedLines = ContextOptimizer.normalizeWhitespace(OutputCondenser.stripEscapes(raw)).split(separator: "\n").map(String.init)
            let restored = Set(OutputCondenser.expandGroups(c.text))
            let lost = cleanedLines.filter { OutputCondenser.isDiagnostic($0) && !restored.contains($0) && !c.text.contains($0) }
            #expect(lost.isEmpty, "\(f.lastPathComponent): \(lost.count) diagnostic line(s) lost, first: \(lost.first ?? "")")
            let b0 = raw.utf8.count, b1 = c.text.utf8.count
            let h0 = TokenEstimator.estimate(raw).tokens, h1 = TokenEstimator.estimate(c.text).tokens
            let pct = b0 == 0 ? "—" : String(format: "%.1f%%", Double(b0 - b1) / Double(b0) * 100)
            let hpct = h0 == 0 ? "—" : String(format: "%.1f%%", Double(h0 - h1) / Double(h0) * 100)
            rows.append("| \(f.deletingPathExtension().lastPathComponent) | \(c.linesBefore) → \(c.linesAfter) | \(b0) → \(b1) | \(pct) | \((b0 + 3) / 4) → \((b1 + 3) / 4) | \(h0) → \(h1) | \(hpct) | \(c.diagnosticLines) / \(lost.isEmpty ? "all kept" : "\(lost.count) LOST") | \(c.steps.map(\.rawValue).joined(separator: ", ").ifEmpty("none")) | \(String(format: "%.1f", ms)) |")
        }
        if let out = ProcessInfo.processInfo.environment["C2D_BENCH_OUT"].map({ $0.replacingOccurrences(of: ".md", with: "-\(mode).md") }) {
            let header = "| fixture | lines | bytes | byte reduction | tokens (bytes/4) | tokens (C2D heuristic) | heuristic reduction | diagnostic lines | steps | ms |\n|---|---|---|---|---|---|---|---|---|---|\n"
            try (header + rows.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}

private extension String { func ifEmpty(_ s: String) -> String { isEmpty ? s : self } }

@Suite struct ContextOptimizeAndHandOffTests {
    @Test func optimizeCondensesOnlyTerminalOutputAndKeepsOriginals() {
        let noisy = ((1...60).map { "Compiling module \($0)/60" } + ["main.swift:3:1: error: boom"]).joined(separator: "\n")
        let payload = ContextPayload(items: [
            ContextItem(id: "t", kind: .terminalOutput, content: noisy),
            ContextItem(id: "f", kind: .file, path: "a.txt", content: noisy),          // files are never condensed
        ])
        #expect(ContextOptimizer.optimize(payload).actions.allSatisfy { $0.kind != .condensedOutput }, "lossless by default: nothing to fold here")
        let r = ContextOptimizer.optimize(payload, output: .init())
        let condensed = r.actions.first { $0.kind == .condensedOutput }
        #expect(condensed?.itemID == "t" && condensed?.originalContent == noisy)
        #expect(r.payload.items.first { $0.id == "t" }?.content.contains("main.swift:3:1: error: boom") == true)
        #expect(r.payload.items.first { $0.id == "f" }?.content == noisy)
        #expect(r.after.tokens < r.before.tokens)
    }

    @Test func handOffFencesOutlastBackticksInContent() {
        let md = ContextOptimizer.handOffMarkdown(ContextPayload(items: [ContextItem(kind: .note, content: "a ```` b")]), title: "T")
        #expect(md.contains("\n`````\na ```` b\n`````\n") && md.hasPrefix("# T\n"))
    }
}
