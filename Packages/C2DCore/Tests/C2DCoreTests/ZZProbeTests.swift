import Foundation
import Testing
@testable import C2DCore

struct ZZProbe {
    // Diagnostic probe from the 2026-10-21 overlap investigation, not a product test: it has no #expect and its
    // result depends on the developer's own ~/.zshrc, so it runs only with `C2D_PTY_PROBE=1`.
    // It used to hang every shell: it waited for "-END\r", but Swift compares Characters and "\r\n" is one
    // grapheme, so "-END\r\n" never contains "-END\r". It now waits for "_-END" (output only; the echoed command
    // line has ")-END") and the read is bounded — the session is terminated after 10 s, which ends the stream.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["C2D_PTY_PROBE"] != nil), arguments: [
        ("sh-inherited", "/bin/sh", [String]()),
        ("zsh-f", "/bin/zsh", ["-f"]),
        ("zsh-i", "/bin/zsh", ["-i"]),
        ("zsh-l", "/bin/zsh", ["-l"]),
    ])
    func probe(_ name: String, _ exe: String, _ args: [String]) async throws {
        let cfg = PTYSessionConfiguration(executable: exe, arguments: args, environment: PTYSessionConfiguration.inheritedEnvironment(),
                                          workingDirectory: NSTemporaryDirectory(), initialSize: TerminalSize(rows: 24, columns: 80))
        let session = PTYSession(configuration: cfg)
        try await session.start()
        let c = OutputCollector(session)
        let deadline = Task { try await Task.sleep(for: .seconds(10)); await session.terminate(gracePeriod: .milliseconds(300)) }
        try await Task.sleep(for: .seconds(3))
        try await session.write(Data("echo PROBE-$(ps -o tpgid=,tty= -p $$ | tr -s ' ' _)-END\n".utf8))
        let t = await c.contains("_-END")
        deadline.cancel()
        #expect(t.contains("_-END"), "\(name) never ran the command; tail: \(t.suffix(200).debugDescription)")
        print("ZZPROBE", name, String(t.components(separatedBy: "PROBE-").last?.prefix(20) ?? ""))
        await session.terminate(gracePeriod: .milliseconds(300)); await session.close()
    }
}
