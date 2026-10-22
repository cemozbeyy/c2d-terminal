import C2DCore
import Foundation

// `PostToolUse` payload on stdin → `updatedToolOutput` response on stdout, or nothing (the CLI keeps the original).
// Always exits 0: a failed fold must never fail or block the tool call.
if let response = TokenSaverHook.postToolUseResponse(payload: FileHandle.standardInput.readDataToEndOfFile()) {
    FileHandle.standardOutput.write(response)
}
exit(0)
