import AppKit
import DustlessKit
import Foundation
import SwiftUI
@testable import DustlessApp

private let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let fixtures = here.appendingPathComponent("Fixtures")
let appSources = here
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources")
let repoRoot = here
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtures.appendingPathComponent(name))
}

func decoded<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    try JSONDecoder().decode(type, from: fixture(name))
}

private func findingJSON(
    tier: String,
    blocked: Bool,
    bytes: UInt64,
    path: String = "/tmp/x",
    desc: String = "d",
    note: [Reason] = []
) -> Data {
    let notes = note.map { reason -> String in
        let params = (reason.params ?? [:]).map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
        return params.isEmpty
            ? "{\"code\":\"\(reason.code)\"}"
            : "{\"code\":\"\(reason.code)\",\"params\":{\(params)}}"
    }.joined(separator: ",")
    return Data("""
    {"ruleId":"r","tier":"\(tier)","desc":"\(desc)","path":"\(path)","bytes":\(bytes),
     "mtime":0,"atime":0,"ageDays":10,"verified":\(!blocked),"blocked":\(blocked),"note":[\(notes)]}
    """.utf8)
}

func finding(
    tier: String,
    blocked: Bool,
    bytes: UInt64,
    path: String = "/tmp/x",
    desc: String = "d",
    note: [Reason] = []
) throws -> Finding {
    try JSONDecoder().decode(
        Finding.self,
        from: findingJSON(tier: tier, blocked: blocked, bytes: bytes, path: path, desc: desc, note: note)
    )
}

typealias MemProcess = DustlessKit.ProcessInfo

func process(command: String, mem: UInt64 = 1, pid: Int = 1) throws -> MemProcess {
    let executable = MemProcess.executablePath(in: command)
    let name = executable.split(separator: "/").last.map(String.init) ?? executable
    return try JSONDecoder().decode(MemProcess.self, from: Data("""
    {"pid":\(pid),"ppid":0,"name":"\(name)","command":"\(command)","cpu":0,"mem":\(mem),
     "owner":"me","root":false,"category":"other"}
    """.utf8))
}

@MainActor
enum TestData {
    static let space = DiskSpace(
        volumeName: "Macintosh HD",
        total: 994_662_584_320,
        used: 512_106_500_096,
        available: 482_556_084_224
    )

    static let scannedAt = Date(timeIntervalSince1970: 1_788_000_000)

    static func report() throws -> ScanReport {
        try decoded(ScanReport.self, "scan.json")
    }

    static func memoryReport() throws -> MemoryReport {
        try decoded(MemoryReport.self, "ram.json")
    }

    static func apps() throws -> [InstalledApp] {
        try decoded([InstalledApp].self, "apps.json")
    }

    static func largeFiles() throws -> [LargeFile] {
        try decoded([LargeFile].self, "largefiles.json")
    }

    static func applyReport() throws -> ApplyReport {
        try decoded(ApplyReport.self, "apply.json")
    }

    static func uninstallReport() throws -> UninstallReport {
        try decoded(UninstallReport.self, "uninstall.json")
    }

    static func settings(_ language: Lang) -> AppSettings {
        let key = "dustless.language"
        let original = UserDefaults.standard.object(forKey: key)
        let settings = AppSettings()
        settings.language = language
        if let original {
            UserDefaults.standard.set(original, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return settings
    }

    static func store(
        report: ScanReport? = nil,
        memory: MemoryReport? = nil,
        apps: [InstalledApp] = [],
        files: [LargeFile] = [],
        engineError: L10nText? = nil,
        selected: Set<String>? = nil
    ) throws -> ScanStore {
        let resolved = try report ?? Self.report()
        return ScanStore(preview: ScanStore.Preview(
            report: report == nil ? resolved : report,
            scannedAt: report == nil ? scannedAt : nil,
            memoryReport: memory,
            diskSpace: space,
            storageVolumes: [VolumeInfo(name: "Macintosh HD", total: space.total, used: space.used, free: space.available)],
            storageApps: apps,
            storageLargeFiles: files,
            selected: selected ?? Set(resolved.deletable.prefix(2).map(\.id)),
            engineError: engineError
        ))
    }

    static func storeWithError(_ error: L10nText) -> ScanStore {
        ScanStore(preview: ScanStore.Preview(report: nil, scannedAt: nil, engineError: error))
    }
}

struct Sandbox {
    enum Violation: Error, CustomStringConvertible {
        case outside(String)

        var description: String {
            switch self {
            case .outside(let path): "the path \(path) is outside the sandbox"
            }
        }
    }

    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dustless-sandbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var rootPath: String {
        var path = root.path
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    func path(_ relative: String) -> String {
        rootPath + "/" + relative
    }

    func makeDirectory(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: path(relative), isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    func makeFile(_ relative: String, contents: String = "fixture\n") throws -> String {
        let target = path(relative)
        let url = URL(fileURLWithPath: target)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return target
    }

    func requireInside(_ path: String) throws -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == prefix || resolved.hasPrefix(prefix + "/") else {
            throw Violation.outside(path)
        }
        return resolved
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: path(relative))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

actor EngineCallRecorder: EngineLauncher {
    struct Call: Equatable {
        let executable: URL
        let arguments: [String]
    }

    private(set) var calls: [Call] = []
    private let result: EngineRun
    private let failure: Error?

    init(result: EngineRun = EngineRun(data: Data("{}".utf8), status: 0, stderr: ""), failure: Error? = nil) {
        self.result = result
        self.failure = failure
    }

    func launch(executable: URL, arguments: [String], timeout: Int) async throws -> EngineRun {
        calls.append(Call(executable: executable, arguments: arguments))
        if let failure { throw failure }
        return result
    }

    var spawnCount: Int { calls.count }
}

enum FakeEngine {
    static func script(
        body: String,
        named name: String = "engine.sh"
    ) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dustless-fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\nset -u\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func scriptPrinting(_ payload: String, status: Int = 0) throws -> URL {
        try script(body: "cat <<'DUSTLESS_EOF'\n\(payload)\nDUSTLESS_EOF\nexit \(status)")
    }

    static func sandboxEngine(sandbox: Sandbox) throws -> URL {
        let root = sandbox.rootPath
        let body = """
        SANDBOX='\(root)'
        sel=''
        prev=''
        target=''
        purge=0
        for a in "$@"; do
          if [ "$prev" = '--only-file' ]; then sel="$a"; fi
          if [ "$prev" = '--uninstall' ] || [ "$prev" = '--delete' ]; then target="$a"; fi
          if [ "$a" = '--purge' ]; then purge=1; fi
          prev="$a"
        done
        outcome() {
          printf '{"ruleId":"e2e","tier":"green","path":"%s","status":"%s","bytes":%s,"detail":%s}' \\
            "$1" "$2" "${3:-1}" "${4:-null}"
        }
        uninstall_outcome() {
          printf '{"path":"%s","status":"%s","bytes":%s,"detail":%s}' \\
            "$1" "$2" "${3:-1}" "${4:-null}"
        }
        inside() {
          case "$1" in
            "$SANDBOX"/?*) return 0 ;;
            *) return 1 ;;
          esac
        }
        to_trash() {
          mkdir -p "$SANDBOX/.Trash"
          base="$(basename "$1")"
          mv "$1" "$SANDBOX/.Trash/$base"
        }
        if [ -n "$target" ]; then
          if ! inside "$target"; then
            printf '{"outcomes":[%s],"summary":{"trashed":0,"purged":0,"skipped":0,"failed":1,"totalBytes":0}}' \\
              "$(uninstall_outcome "$target" failed 0 '{"code":"outside_roots"}')"
            exit 0
          fi
          case "$target" in
            "$SANDBOX"/red/?*)
              printf '{"outcomes":[%s],"summary":{"trashed":0,"purged":0,"skipped":0,"failed":1,"totalBytes":0}}' \\
                "$(uninstall_outcome "$target" failed 0 '{"code":"red_list"}')"
              exit 0
              ;;
          esac
          if [ ! -e "$target" ]; then
            printf '{"outcomes":[%s],"summary":{"trashed":0,"purged":0,"skipped":1,"failed":0,"totalBytes":0}}' \\
              "$(uninstall_outcome "$target" skipped 0 '{"code":"not_found"}')"
            exit 0
          fi
          if [ "$purge" = "1" ]; then
            rm -rf "$target"
            printf '{"outcomes":[%s],"summary":{"trashed":0,"purged":1,"skipped":0,"failed":0,"totalBytes":1}}' \\
              "$(uninstall_outcome "$target" purged)"
          else
            to_trash "$target"
            printf '{"outcomes":[%s],"summary":{"trashed":1,"purged":0,"skipped":0,"failed":0,"totalBytes":1}}' \\
              "$(uninstall_outcome "$target" trashed)"
          fi
          exit 0
        fi
        if [ -z "$sel" ]; then
          printf '{"schemaVersion":2,"outcomes":[],"deletedBytes":0,"freed":0,"freeBefore":0,"freeAfter":0,"elapsedMs":1}'
          exit 0
        fi
        outcomes="$SANDBOX/.outcomes"
        : > "$outcomes"
        cat "$sel" | tr -d '[]"' | sed 's/\\\\//g' | tr ',' '\\n' | while IFS= read -r p || [ -n "$p" ]; do
          [ -n "$p" ] || continue
          if ! inside "$p"; then
            printf '%s\\n' "$(outcome "$p" failed 1 '{"code":"denied_path"}')" >> "$outcomes"
            continue
          fi
          case "$p" in
            "$SANDBOX"/red/?*)
              printf '%s\\n' "$(outcome "$p" failed 1 '{"code":"red_list"}')" >> "$outcomes"
              continue
              ;;
          esac
          if [ ! -e "$p" ]; then
            printf '%s\\n' "$(outcome "$p" skipped 0 '{"code":"not_found"}')" >> "$outcomes"
            continue
          fi
          rm -rf "$p"
          printf '%s\\n' "$(outcome "$p" deleted 1)" >> "$outcomes"
        done
        printf '{"schemaVersion":2,"outcomes":['
        first=1
        while IFS= read -r line; do
          if [ "$first" = "0" ]; then printf ','; fi
          first=0
          printf '%s' "$line"
        done < "$outcomes"
        printf '],"deletedBytes":1,"freed":1,"freeBefore":0,"freeAfter":1,"elapsedMs":1}'
        """
        return try script(body: body)
    }
}

final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func read() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

actor SandboxLauncher: EngineLauncher {
    enum Failure: Error, CustomStringConvertible {
        case spawnCapReached(Int)

        var description: String {
            switch self {
            case .spawnCapReached(let cap): "the engine was launched more than \(cap) times"
            }
        }
    }

    private let home: String
    private let cap: Int
    private var launches = 0
    private var pids: [Int32] = []

    init(home: String, cap: Int = 8) {
        self.home = home
        self.cap = cap
    }

    var spawnCount: Int { launches }
    var spawnedPids: [Int32] { pids }

    func launch(executable: URL, arguments: [String], timeout: Int) async throws -> EngineRun {
        launches += 1
        guard launches <= cap else { throw Failure.spawnCapReached(cap) }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = home
            environment["TMPDIR"] = home
            process.environment = environment
            let outURL = URL(fileURLWithPath: home).appendingPathComponent(".engine.out")
            let errURL = URL(fileURLWithPath: home).appendingPathComponent(".engine.err")
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
            FileManager.default.createFile(atPath: errURL.path, contents: nil)
            do {
                process.standardOutput = try FileHandle(forWritingTo: outURL)
                process.standardError = try FileHandle(forWritingTo: errURL)
            } catch {
                continuation.resume(throwing: error)
                return
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            let pid = process.processIdentifier
            pids.append(pid)
            let timedOut = TimeoutFlag()
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) {
                timedOut.set()
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
            process.waitUntilExit()
            let status = process.terminationStatus
            let outData = (try? Data(contentsOf: outURL)) ?? Data()
            let errData = (try? Data(contentsOf: errURL)) ?? Data()
            guard !timedOut.read() else {
                continuation.resume(throwing: DustlessError.timedOut(timeout))
                return
            }
            continuation.resume(returning: EngineRun(
                data: outData,
                status: status,
                stderr: String(data: errData, encoding: .utf8) ?? ""
            ))
        }
    }
}
