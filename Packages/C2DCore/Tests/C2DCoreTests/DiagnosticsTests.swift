import Foundation
import Testing
@testable import C2DCore

@Suite struct DiagnosticsTests {

    // MARK: Redaction

    @Test func redactsRealisticSecrets() {
        let cases: [(String, String)] = [
            ("token=ghp_0123456789abcdefghijklmnopqrstuvwxyz", "ghp_"),
            ("AWS AKIA1234567890ABCDEF here", "AKIA1234567890ABCDEF"),
            ("Authorization: Bearer abc.def.ghi0123456789", "abc.def.ghi"),
            ("api_key: \"sk-ant-secret-value-goes-here-123456\"", "sk-ant-secret-value"),
            ("https://alice:hunter2@github.com/x/y.git", "hunter2"),
            ("password = s3cr3tP@ssw0rd!", "s3cr3tP@ssw0rd"),
        ]
        for (input, secret) in cases {
            let out = SecretRedactor.redact(input)
            #expect(!out.contains(secret), "leaked \(secret) in: \(out)")
            #expect(out.contains("REDACTED"))
        }
    }

    @Test func redactsPrivateKeyBlock() {
        let key = "-----BEGIN RSA PRIVATE KEY-----\nMIIEoCAFAKEKEYLINE1\nMORELINES2\n-----END RSA PRIVATE KEY-----"
        let out = SecretRedactor.redact("here is\n\(key)\ndone")
        #expect(out.contains("[REDACTED-PRIVATE-KEY]") && !out.contains("FAKEKEYLINE"))
    }

    @Test func keepsGitShaButRedactsOpaqueTokens() {
        let sha = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"   // 40 hex
        #expect(SecretRedactor.redact("commit \(sha) ok").contains(sha), "git SHAs must survive")
        let opaque = "Zx9Qw8Er7Ty6Ui5Op4As3Df2Gh1Jk0LzXcVbNmQw"   // 40 non-hex
        #expect(!SecretRedactor.redact("tok \(opaque)").contains(opaque))
    }

    @Test func redactsHomeUsername() {
        let out = SecretRedactor.redact("/Users/alice/project/f.swift")
        #expect(!out.contains("alice") && out.contains("~"))
    }

    // MARK: Classification / outcome

    @Test func classifierPreservesUnknownOnTermination() {
        #expect(DiagnosticClassifier.classify(GitError.commandFailed(code: 143, stderr: "x")).outcome == .unknown)
        #expect(DiagnosticClassifier.classify(GitError.commandFailed(code: 1, stderr: "x")).outcome == .failure)
        #expect(DiagnosticClassifier.classify(GitError.identityNotConfigured).reason == "identityNotConfigured")
        // Associated values (stderr) never surface as fields.
        let c = DiagnosticClassifier.classify(GitError.commandFailed(code: 1, stderr: "ghp_secrettoken"))
        #expect(c.reason == nil && c.exitCode == 1)
    }

    // MARK: Recorder + bundle (structural safety)

    private func report() -> DiagnosticsReport {
        DiagnosticsReport(appVersion: "1.0", buildNumber: "1", osVersion: "15.0.0", architecture: "arm64")
    }

    @Test func bundleContainsOnlyAllowlistedKeysAndNoSecretsAtDefaultVerbosity() async throws {
        let rec = DiagnosticsRecorder()   // .normal
        // An error whose stderr is packed with secrets — the realistic leak vector.
        let stderr = "fatal: Authentication failed for 'https://bob:ghp_abcdefghijklmnopqrstuvwxyz0123456789@github.com' token=AKIA1234567890ABCDEF\n-----BEGIN OPENSSH PRIVATE KEY-----\nLEAK\n-----END OPENSSH PRIVATE KEY-----"
        await rec.record(module: "git", operation: "push", error: GitError.commandFailed(code: 128, stderr: stderr))
        await rec.record(module: "app", operation: "boom", detail: stderr)
        let json = try await rec.makeBundle(report: report()).serialized()

        for secret in ["ghp_abcdefghijklmnopqrstuvwxyz0123456789", "AKIA1234567890ABCDEF", "bob:ghp", "LEAK"] {
            #expect(!json.contains(secret), "bundle leaked \(secret)")
        }
        // Structural: every event object's keys are a subset of the allowlist.
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let events = obj["events"] as! [[String: Any]]
        #expect(events.count == 2)
        for e in events { #expect(Set(e.keys).isSubset(of: DiagnosticEvent.allowedKeys), "unexpected keys: \(Set(e.keys).subtracting(DiagnosticEvent.allowedKeys))") }
        // Default verbosity carries no detail at all.
        #expect(events.allSatisfy { $0["detail"] == nil })
        #expect(obj["includesDetail"] as? Bool == false)
    }

    @Test func verboseDetailRunsTheRedactorAndKeepsItSafe() async throws {
        // At verbose the detail path is actually exercised — this is the test that fails if the
        // redactor regresses (the .normal structural test drops detail and would pass regardless).
        let rec = DiagnosticsRecorder(verbosity: .verbose)
        let stderr = "auth failed https://bob:ghp_abcdefghijklmnopqrstuvwxyz0123456789@github.com key AKIA1234567890ABCDEF jwt eyJaaa.eyJbbb.ccc\n-----BEGIN RSA PRIVATE KEY-----\nLEAKLINE\n-----END RSA PRIVATE KEY-----"
        await rec.record(module: "app", operation: "op", detail: stderr)
        let json = try await rec.makeBundle(report: report()).serialized()
        for secret in ["ghp_abcdefghijklmnopqrstuvwxyz0123456789", "AKIA1234567890ABCDEF", "bob:ghp", "LEAKLINE", "eyJaaa.eyJbbb"] {
            #expect(!json.contains(secret), "verbose detail leaked \(secret)")
        }
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let event = (obj["events"] as! [[String: Any]])[0]
        #expect(event["detail"] != nil, "detail must be present at verbose, so we know the redactor path ran")
        #expect(Set(event.keys).isSubset(of: DiagnosticEvent.allowedKeys))
    }

    @Test func providerPatternsDoNotMatchOrdinaryWords() {
        // \b-anchored, so "task-…" is not mistaken for an "sk-…" token.
        #expect(SecretRedactor.redact("task-abcdefghijklmnop") == "task-abcdefghijklmnop")
        #expect(SecretRedactor.redact("a basket-of-items here") == "a basket-of-items here")
    }

    @Test func bufferIsBounded() async throws {
        let rec = DiagnosticsRecorder(capacity: 10)
        for i in 0..<50 { await rec.record(module: "m", operation: "op\(i)") }
        #expect(await rec.snapshot().count == 10, "ring buffer caps at capacity")
    }

    @Test func serializationRoundTrips() async throws {
        let rec = DiagnosticsRecorder()
        await rec.record(module: "git", operation: "status", error: GitError.nothingToCommit)
        let json = try await rec.makeBundle(report: report()).serialized()
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(DiagnosticsBundle.self, from: Data(json.utf8))
        #expect(back.events.count == 1 && back.report.appVersion == "1.0" && back.events[0].reason == "nothingToCommit")
    }
}
