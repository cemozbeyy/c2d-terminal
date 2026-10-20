import Foundation
import Testing
@testable import C2DCore

struct ZZProbe {
    @Test(arguments: [
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
        try await Task.sleep(for: .seconds(3))
        try await session.write(Data("echo PROBE-$(ps -o tpgid=,tty= -p $$ | tr -s ' ' _)-END\n".utf8))
        let t = await c.contains("-END\r")
        print("ZZPROBE", name, t.components(separatedBy: "PROBE-").last?.prefix(20) ?? "")
        await session.terminate(gracePeriod: .milliseconds(300)); await session.close()
    }
}
