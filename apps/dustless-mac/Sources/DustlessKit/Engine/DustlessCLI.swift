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

    public func apply(only paths: [String]) async throws -> ApplyReport {
        let selection = try writeSelection(paths)
        defer { try? FileManager.default.removeItem(at: selection) }
        return try await decode(
            ApplyReport.self,
            from: run(["apply", "--json", "--yes", "--only-file", selection.path])
        )
    }

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

    public func uninstallApp(path: String, purge: Bool = false) async throws -> UninstallReport {
        var args = ["apps", "--uninstall", path, "--confirm", "--json"]
        if purge { args.append("--purge") }
        return try await decode(UninstallReport.self, from: run(args))
    }

    public func largefiles() async throws -> [LargeFile] {
        try await decode([LargeFile].self, from: run(["largefiles", "--json"]))
    }

    public func deleteLargeFile(path: String) async throws -> UninstallReport {
        try await decode(UninstallReport.self, from: run(["largefiles", "--delete", path, "--confirm", "--json"]))
    }

    public func kill(pid: Int, force: Bool = false, sigkill: Bool = false) async throws -> RamKillResult {
        var args = ["ram", "--kill", "\(pid)", "--confirm", "--json"]
        if force { args.append("--force") }
        if sigkill { args.append("--sigkill") }
        return try await decode(RamKillResult.self, from: run(args))
    }

    public func awdl() async throws -> AwdlReport {
        try await decode(AwdlReport.self, from: run(["awdl", "--json"]))
    }

    public func setAwdl(on: Bool) async throws -> AwdlReport {
        try await decode(AwdlReport.self, from: run(["awdl", on ? "--on" : "--off", "--json"]))
    }

    public func awdlPrivilege() async throws -> AwdlPrivilege {
        try await decode(AwdlPrivilege.self, from: run(["awdl", "--print-privilege", "--json"]))
    }

    public func net() async throws -> NetReport {
        try await decode(NetReport.self, from: run(["net", "--advanced", "--json"]))
    }

    public func runNetOp(_ id: String, force: Bool, privilegeInstalled: Bool = false) async throws -> NetReport {
        guard let op = NetOp(rawValue: id) else {
            throw DustlessError.unreadableOutput("unknown network operation \"\(id)\"")
        }
        let arguments = ["net", op.flag, "--json"] + (force ? ["--force"] : [])
        let viaPrompt = op.isAdvanced && !privilegeInstalled
        let result = viaPrompt ? try await runAsRoot(arguments) : try await run(arguments)
        return try decode(NetReport.self, from: result)
    }

    public func netPrivilege() async throws -> NetPrivilege {
        try await decode(NetPrivilege.self, from: run(["net", "--print-privilege", "--json"]))
    }

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

    private func sh(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func decode<T: Decodable>(_ type: T.Type, from result: RunResult) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: result.data)
        } catch {
            if result.status == 0 {
                let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw DustlessError.unreadableOutput(reason.isEmpty ? String(describing: error) : reason)
            }
            if result.stderr.localizedCaseInsensitiveContains("not found") {
                throw BinaryLocationError.notFound([executable])
            }
            if let message = Self.engineMessage(in: result.data) {
                throw DustlessError.exited(status: result.status, stderr: message)
            }
            throw DustlessError.exited(status: result.status, stderr: result.stderr)
        }
    }

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

    private func run(executable tool: URL, _ arguments: [String]) async throws -> RunResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RunResult, Error>) in
            let running = RunningProcess()
            let out = LockedBox(Data())
            let err = LockedBox(Data())
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