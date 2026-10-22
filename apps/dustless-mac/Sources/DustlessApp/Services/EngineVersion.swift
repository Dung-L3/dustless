import DustlessKit
import Foundation

enum EngineVersion {
    static func read() async -> String? {
        guard let cli = try? DustlessCLI.resolve() else { return nil }
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = cli.executable
                process.arguments = ["version"]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let text = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: text?.isEmpty == false ? text : nil)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
