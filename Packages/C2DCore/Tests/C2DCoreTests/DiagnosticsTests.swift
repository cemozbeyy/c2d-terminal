import Testing
@testable import C2DCore

@Test func summaryIncludesEveryField() {
    let r = DiagnosticsReport(appVersion: "1.2.3", buildNumber: "42", osVersion: "15.1.0", architecture: "arm64")
    #expect(r.summary == "C2D Terminal 1.2.3 (42) · macOS 15.1.0 · arm64")
}

@Test func currentReportNeverHasEmptyFields() {
    let r = DiagnosticsReport.current()
    #expect(!r.appVersion.isEmpty)
    #expect(!r.buildNumber.isEmpty)
    #expect(r.osVersion.split(separator: ".").count == 3)
    #expect(["arm64", "x86_64"].contains(r.architecture))
}
