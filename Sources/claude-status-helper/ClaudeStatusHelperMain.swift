import Darwin
import Foundation
import QuotaPulseKit

@main
enum ClaudeStatusHelperMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2, arguments[0] == "--cache-file" else {
            writeError("usage: claude-status-helper --cache-file <path>")
            exit(64)
        }

        do {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let statusLine = try ClaudeStatusLineHelper.run(
                input: input,
                cacheURL: URL(fileURLWithPath: arguments[1])
            )
            FileHandle.standardOutput.write(Data((statusLine + "\n").utf8))
        } catch {
            writeError("claude-status-helper: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
