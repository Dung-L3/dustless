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

    /// Deletes exactly the paths the user picked, and nothing else.
    ///
    /// The engine re-scans on its own (`src/cli.ts` `runApply()`), so a bare
    /// `apply` would act on whatever that fresh scan happened to find. The
    /// selection is passed as a JSON array of absolute paths in a temp file, and
    /// the engine skips any finding outside it (`--only-file`), which is what
    /// keeps ticking one row from deleting every green/yellow finding. It never
    /// widens the set: blocked and red findings stay refused either way.
    ///
    /// Callers must pass a non-empty list — an empty selection is a no-op the
    /// caller decides, not an engine run that deletes nothing.
    public func apply(only paths: [String]) async throws -> ApplyReport {
        let selection = try writeSelection(paths)
        // The file is a list of the user's own paths, so it must not outlive the
        // run: one `defer` covers the throw, the timeout and the cancelled task.
        defer { try? FileManager.default.removeItem(at: selection) }
        return try await decode(
            ApplyReport.self,
            from: run(["apply", "--json", "--yes", "--only-file", selection.path])
        )
    }

    /// Writes the selection where the engine can read it before it scans, so a
    /// path that cannot be written is an error and nothing is deleted.
    private func writeSelection(_ paths: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dustless-only-\(UUID().uuidString).json")
        try JSONEncoder().encode(paths).write(to: url, options: .atomic)
        return url
    }

    public func ram() async throws -> MemoryReport {
        try await decode(MemoryReport.self, from: run(["ram", "--json"]))
    }

    public func apps() async throws -> [InstalledApp] {
        try await decode([InstalledApp].self, from: run(["apps", "--json"]))
    }

    /// Removes an application for good.
    ///
    /// `purge: true` adds the engine's `--purge`, which `rm -rf`s the bundle and
    /// its leftovers instead of moving them to the Trash — nothing is recoverable
    /// afterwards, which is why the confirmation says so. The engine still runs
    /// its own safety validation (bundle id, paths under HOME, the red list)
    /// before anything is deleted, and a refusal comes back as a report whose
    /// outcome is `failed`, not as a silent fallback to the Trash.
    public func uninstallApp(path: String, purge: Bool = false) async throws -> UninstallReport {
        var args = ["apps", "--uninstall", path, "--confirm", "--json"]
        if purge { args.append("--purge") }
        return try await decode(UninstallReport.self, from: run(args))
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

    /// The live network state, read without changing anything: with `--advanced`
    /// and no named operation `selectOps()` returns an empty list, so the engine
    /// inspects and runs nothing. Without `--advanced` a bare `net` flushes the
    /// DNS cache, which is not what a state read should do.
    public func net() async throws -> NetReport {
        try await decode(NetReport.self, from: run(["net", "--advanced", "--json"]))
    }

    /// Runs exactly one network operation and decodes its report.
    ///
    /// Advanced operations need root and the engine refuses without it, so they
    /// run through one admin prompt: scoped to this single command, per run, with
    /// nothing left behind in /etc/sudoers.d when it is over. A safe operation
    /// runs directly, so the app never asks for a password it does not need.
    /// `privilegeInstalled` says the scoped sudo rule is in place. When it is,
    /// the engine escalates through `sudo -n` itself and never prompts, so the
    /// app must run it directly; when it is not, one admin prompt per run is
    /// the only way to root and the operation still has to work.
    public func runNetOp(_ id: String, force: Bool, privilegeInstalled: Bool = false) async throws -> NetReport {
        guard let op = NetOp(rawValue: id) else {
            throw DustlessError.unreadableOutput("unknown network operation \"\(id)\"")
        }
        let arguments = ["net", op.flag, "--json"] + (force ? ["--force"] : [])
        let viaPrompt = op.isAdvanced && !privilegeInstalled
        let result = viaPrompt ? try await runAsRoot(arguments) : try await run(arguments)
        return try decode(NetReport.self, from: result)
    }

    /// The exact sudoers rule for the one-time "remember this authorization"
    /// step. No root needed: the engine only reads the current interface and
    /// service to fill it in.
    public func netPrivilege() async throws -> NetPrivilege {
        try await decode(NetPrivilege.self, from: run(["net", "--print-privilege", "--json"]))
    }

    /// Runs the engine as root through the standard macOS admin prompt.
    ///
    /// `|| true` is deliberate: the engine prints its whole report and *then*
    /// exits 1 whenever an outcome failed or was refused, and osascript turns a
    /// non-zero exit into an error that throws that report away. The report is
    /// the answer, so keep it — a run that prints no JSON still fails in
    /// `decode`, and a cancelled prompt fails there with osascript's own message.
    private func runAsRoot(_ arguments: [String]) async throws -> RunResult {
        let line = ([sh(executable.path)] + arguments).joined(separator: " ") + " || true"
        let literal = line
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return try await run(
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            ["-e", "do shell script \"\(literal)\" with administrator privileges"]
        )
    }

    /// Single-quote one value for /bin/sh. Values here are the resolved engine
    /// path and our own flag names, never user input.
    private func sh(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
                // A zero exit with no readable JSON usually means the shell said
                // why on stderr (a missing tool, a denied prompt); prefer that
                // sentence over a decoding error nobody can act on.
                let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw DustlessError.unreadableOutput(reason.isEmpty ? String(describing: error) : reason)
            }
            if result.stderr.localizedCaseInsensitiveContains("not found") {
                throw BinaryLocationError.notFound([executable])
            }
            // With `--json` the engine reports an argument or validation error as
            // `{"error":"…"}` on stdout and exits 1 without saying it on stderr
            // (`fail()` in `src/cli.ts`), so the reason sits in the very bytes
            // that failed to decode. Fall back to the exit status when it is not
            // that shape.
            if let message = Self.engineMessage(in: result.data) {
                throw DustlessError.exited(status: result.status, stderr: message)
            }
            throw DustlessError.exited(status: result.status, stderr: result.stderr)
        }
    }

    /// `{"error": "…"}`, the one shape the engine gives a machine caller when it
    /// refuses a run. `nil` for every other payload, including a valid report.
    private struct EngineRefusal: Decodable {
        let error: String
    }

    private static func engineMessage(in data: Data) -> String? {
        guard let refusal = try? JSONDecoder().decode(EngineRefusal.self, from: data) else { return nil }
        let message = refusal.error.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    private struct RunResult: Sendable {
        let data: Data
        let status: Int32
        let stderr: String
    }

    private func run(_ arguments: [String]) async throws -> RunResult {
        try await run(executable: executable, arguments)
    }

    /// One process launch: the pipes, the deadline and the exit status are the
    /// same whether the engine runs as this user or as root under osascript, so
    /// both paths share this instead of growing a second copy.
    private func run(executable tool: URL, _ arguments: [String]) async throws -> RunResult {
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
                process.executableURL = tool
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
