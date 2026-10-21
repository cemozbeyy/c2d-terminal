import C2DCore
import Foundation

/// Token Saver engine modes (ADR-033) run headless and exit before any app state exists; anything else is the app.
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.count == 2, args[1] == TokenSaverEngine.hookFlag {
            if let response = TokenSaverEngine.hookResponse(payload: FileHandle.standardInput.readDataToEndOfFile(), runner: Bundle.main.executablePath ?? args[0]) {
                FileHandle.standardOutput.write(response)
            }
            exit(0)   // never blocks the tool call: no response = run it unchanged
        }
        if args.count == 3, args[1] == TokenSaverEngine.runFlag {
            exit(TokenSaverEngine.run(command: args[2]))
        }
        C2DTerminalApp.main()
    }
}
