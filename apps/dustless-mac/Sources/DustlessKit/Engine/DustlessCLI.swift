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

    /// Lets a caller (or a test) point the helper at any executable, not only
    /// the one `BinaryLocator` resolves.
    public init(executable: URL, timeout: Int = 900) {
        self.executable = executable
        self.timeout = timeout
    }

    public static func resolve(timeout: Int = 900) throws -> DustlessCLI {
        DustlessCLI(executable: try BinaryLocator.locate(), timeout: timeout)
    }

    public func scan() async throws -> ScanReport {
        try await decode(ScanReport.self, from: run(["scan", "--json"]))
    }

    public func apply() async throws -> ApplyReport {
        try await decode(ApplyReport.self, from: run(["apply", "--json", "--yes"]))
    }

    public func ram() async throws -> MemoryReport {
        try await decode(MemoryReport.self, from: run(["ram", "--json"]))
    }

    public func apps() async throws -> [InstalledApp] {
        try await decode([InstalledApp].self, from: run(["apps", "--json"]))
    }

    public func uninstallApp(path: String) async throws -> UninstallReport {
        try await decode(UninstallReport.self, from: run(["apps", "--uninstall", path, "--confirm", "--json"]))
    }

    /// The engine's own defaults: files over 200 MiB, the biggest 50 first.
    public func largefiles() async throws -> [LargeFile] {
        try await decode([LargeFile].self, from: run(["largefiles", "--json"]))
    }

    /// Reports the same shape as `uninstallApp()` — one outcome, one summary —
    /// because both commands move a path to the Trash and nothing is ever
    /// hard-deleted.
    public func deleteLargeFile(path: String) async throws -> UninstallReport {
        try await decode(UninstallReport.self, from: run(["largefiles", "--delete", path, "--confirm", "--json"]))
    }

    public func kill(pid: Int, force: Bool = false, sigkill: Bool = false) async throws -> RamKillResult {
        var args = ["ram", "--kill", "\(pid)", "--confirm", "--json"]
        if force { args.append("--force") }
        if sigkill { args.append("--sigkill") }
        return try await decode(RamKillResult.self, from: run(args))
    }

    /// The live AWDL (AirDrop) state. Read-only, so it is safe to call freely.
    public func awdl() async throws -> AwdlReport {
        try await decode(AwdlReport.self, from: run(["awdl", "--json"]))
    }

    /// Toggle AWDL. The engine escalates through the scoped sudo rule itself, so
    /// the returned report's outcome says whether the change was allowed.
    public func setAwdl(on: Bool) async throws -> AwdlReport {
        try await decode(AwdlReport.self, from: run(["awdl", on ? "--on" : "--off", "--json"]))
    }

    /// The exact sudoers rule to install for a password-free toggle.
    public func awdlPrivilege() async throws -> AwdlPrivilege {
        try await decode(AwdlPrivilege.self, from: run(["awdl", "--print-privilege", "--json"]))
    }

    /// The engine prints a full JSON report and *then* exits 1 whenever an
    /// outcome failed or was refused (`apply`, `ram --kill`, `apps --uninstall`,
    /// `largefiles --delete`), so a non-zero status is not by itself a failure:
    /// the report is the answer. Decode first; only when no JSON reads do we fall
    /// back to the exit status, keeping the real reason for a genuine failure.
    private func decode<T: Decodable>(_ type: T.Type, from result: RunResult) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: result.data)
        } catch {
            if result.status == 0 {
                throw DustlessError.unreadableOutput(String(describing: error))
            }
            if result.stderr.localizedCaseInsensitiveContains("not found") {
                throw BinaryLocationError.notFound([executable])
            }
            throw DustlessError.exited(status: result.status, stderr: result.stderr)
        }
    }

    private struct RunResult: Sendable {
        let data: Data
        let status: Int32
        let stderr: String
    }

    private func run(_ arguments: [String]) async throws -> RunResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RunResult, Error>) in
            let running = RunningProcess()
            let out = LockedBox(Data())
            let err = LockedBox(Data())
            // Set by the deadline below, read once the child is gone, so a run
            // that ended because time ran out reports `.timedOut` rather than the
            // signal-delivered exit status.
            let timedOut = LockedBox(false)
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

                // The deadline must live OFF this serial queue: this queue then
                // blocks in `readers.wait()`/`waitUntilExit()` until the child is
                // gone, so a timer scheduled here could never fire and a hung
                // engine would hang the app forever.
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) {
                    timedOut.mutate { $0 = true }
                    running.cancel()
                }

                readers.wait()
                process.waitUntilExit()
                running.finish()

                if timedOut.read() {
                    continuation.resume(throwing: DustlessError.timedOut(timeout))
                    return
                }

                continuation.resume(returning: RunResult(
                    data: out.read(),
                    status: process.terminationStatus,
                    stderr: String(data: err.read(), encoding: .utf8) ?? ""
                ))
            }
        }
    }
}
