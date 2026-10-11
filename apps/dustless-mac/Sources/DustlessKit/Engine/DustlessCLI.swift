import Foundation

public enum DustlessError: LocalizedError {
    case launchFailed(String)
    case exited(status: Int32, stderr: String)
    case timedOut(Int)
    case unreadableOutput(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let reason):
            return "Could not start the dustless engine: \(reason)"
        case .exited(let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "The dustless engine exited with status \(status)."
                : "The dustless engine failed (status \(status)): \(detail)"
        case .timedOut(let seconds):
            return "The dustless engine did not finish within \(seconds) seconds."
        case .unreadableOutput(let reason):
            return "The dustless engine returned output this app could not read: \(reason)"
        }
    }

    /// The same message as a translatable key, so the UI can render it in the
    /// user's language instead of the engine layer hard-coding English.
    public var localized: L10nText {
        switch self {
        case .launchFailed(let reason):
            return L10nText("errLaunchFailed", ["reason": reason])
        case .exited(let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? L10nText("errExited", ["status": "\(status)"])
                : L10nText("errExitedDetail", ["status": "\(status)", "detail": detail])
        case .timedOut(let seconds):
            return L10nText("errTimedOut", ["seconds": "\(seconds)"])
        case .unreadableOutput(let reason):
            return L10nText("errUnreadable", ["reason": reason])
        }
    }
}

public struct DustlessCLI: Sendable {
    public let executable: URL
    public let timeout: Int

    public static func resolve(timeout: Int = 900) throws -> DustlessCLI {
        DustlessCLI(executable: try BinaryLocator.locate(), timeout: timeout)
    }

    public func scan() async throws -> ScanReport {
        try await decode(ScanReport.self, from: run(["scan", "--json"]))
    }

    public func apply() async throws -> ApplyReport {
        try await decode(ApplyReport.self, from: run(["apply", "--json", "--yes"]))
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DustlessError.unreadableOutput(String(describing: error))
        }
    }

    private func run(_ arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let running = RunningProcess()
            let out = LockedBox(Data())
            let err = LockedBox(Data())
            let queue = DispatchQueue(label: "dustless.engine", qos: .userInitiated)

            queue.async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: DustlessError.launchFailed(error.localizedDescription))
                    return
                }
                running.attach(process)

                let readers = DispatchGroup()
                for (handle, sink) in [(outPipe.fileHandleForReading, out), (errPipe.fileHandleForReading, err)] {
                    readers.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let data = handle.readDataToEndOfFile()
                        sink.mutate { $0 = data }
                        readers.leave()
                    }
                }

                queue.asyncAfter(deadline: .now() + .seconds(timeout)) { running.cancel() }

                readers.wait()
                process.waitUntilExit()
                running.finish()

                let status = process.terminationStatus
                let outData = out.read()
                let errText = String(data: err.read(), encoding: .utf8) ?? ""

                if status == 0 {
                    continuation.resume(returning: outData)
                } else if errText.localizedCaseInsensitiveContains("not found") {
                    continuation.resume(throwing: BinaryLocationError.notFound([executable]))
                } else {
                    continuation.resume(throwing: DustlessError.exited(status: status, stderr: errText))
                }
            }
        }
    }
}
