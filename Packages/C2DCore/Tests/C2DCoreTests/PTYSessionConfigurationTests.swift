import Foundation
import Testing
@testable import C2DCore

/// Deterministic checks: nothing here spawns a process.
@Suite struct PTYSessionConfigurationTests {
    private let env = ["PATH": "/usr/bin:/bin"]

    @Test func validConfigurationPasses() throws {
        try PTYSessionConfiguration(executable: "/bin/sh", environment: env, workingDirectory: "/tmp").validate()
    }

    @Test func missingExecutableIsRejected() {
        let c = PTYSessionConfiguration(executable: "/nonexistent/shell", environment: env, workingDirectory: "/tmp")
        #expect(throws: PTYError.invalidExecutable(path: "/nonexistent/shell")) { try c.validate() }
    }

    @Test func relativeExecutableIsRejected() {
        let c = PTYSessionConfiguration(executable: "sh", environment: env, workingDirectory: "/tmp")
        #expect(throws: PTYError.invalidExecutable(path: "sh")) { try c.validate() }
    }

    @Test func missingWorkingDirectoryIsRejected() {
        let c = PTYSessionConfiguration(executable: "/bin/sh", environment: env, workingDirectory: "/no/such/dir")
        #expect(throws: PTYError.invalidWorkingDirectory(path: "/no/such/dir")) { try c.validate() }
    }

    @Test func fileAsWorkingDirectoryIsRejected() {
        let c = PTYSessionConfiguration(executable: "/bin/sh", environment: env, workingDirectory: "/bin/sh")
        #expect(throws: PTYError.invalidWorkingDirectory(path: "/bin/sh")) { try c.validate() }
    }

    @Test func zeroSizeIsRejected() {
        let c = PTYSessionConfiguration(executable: "/bin/sh", environment: env, workingDirectory: "/tmp",
                                        initialSize: TerminalSize(rows: 0, columns: 80))
        #expect(throws: PTYError.invalidSize) { try c.validate() }
    }

    @Test func environmentKeyWithEqualsIsRejected() {
        let c = PTYSessionConfiguration(executable: "/bin/sh", environment: ["A=B": "x"], workingDirectory: "/tmp")
        #expect(throws: PTYError.invalidEnvironmentKey("A=B")) { try c.validate() }
    }

    @Test func loginShellIsAnAbsoluteExecutable() throws {
        let shell = try PTYSessionConfiguration.loginShell()
        #expect(shell.hasPrefix("/"))
        #expect(access(shell, X_OK) == 0)
    }

    @Test func inheritedEnvironmentSetsTERM() {
        #expect(PTYSessionConfiguration.inheritedEnvironment(term: "dumb")["TERM"] == "dumb")
    }

    @Test func errorsCarryNoEnvironmentValues() {
        // The error type can only hold paths, keys and errno values by construction.
        let e: PTYError = .spawnFailed(errno: 13)
        #expect(String(describing: e) == "spawnFailed(errno: 13)")
    }
}
