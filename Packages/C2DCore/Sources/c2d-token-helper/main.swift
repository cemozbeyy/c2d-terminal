import C2DCore
import Foundation

// `PostToolUse` payload on stdin → `updatedToolOutput` response on stdout, or nothing (the CLI keeps the original).
// Always exits 0: a failed fold must never fail or block the tool call.
// Default: the byte-exact fold (ADR-035). `--lossy <similar|longline|truncate|all>`: the opt-in lossy condenser,
// for the owner's quality experiment only (hookcheck arm `c2d-lossy`); never used by any launch.
var lossy: TokenSaverHook.LossyVariant?
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    if arg == "--lossy", let v = args.popFirst(), let variant = TokenSaverHook.LossyVariant(rawValue: v) { lossy = variant }
    else { exit(0) }   // unknown argument: do nothing rather than guess (the CLI keeps the original output)
}
if let response = TokenSaverHook.postToolUseResponse(payload: FileHandle.standardInput.readDataToEndOfFile(), lossy: lossy) {
    FileHandle.standardOutput.write(response)
}
exit(0)
