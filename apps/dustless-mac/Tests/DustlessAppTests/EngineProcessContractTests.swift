import Testing
import Foundation
import DustlessKit
@Suite("engine process contract", .serialized)
struct EngineProcessContractTests {
    private func script(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dustless-engine-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("engine.sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func decodesTheReportEvenWhenTheEngineExitsNonZero() async throws {
        let json = String(decoding: try fixture("scan.json"), as: UTF8.self)
        let cli = DustlessCLI(
            executable: try script("cat <<'DUSTLESS_EOF'\n\(json)\nDUSTLESS_EOF\nexit 1"),
            timeout: 5
        )
        let report = try await cli.scan()
        #expect(report.platform == "mac")
        #expect(!report.findings.isEmpty)
    }

    @Test func aNonJSONFailureStillThrowsTheExitStatus() async throws {
        let cli = DustlessCLI(executable: try script("echo 'boom' >&2\nexit 3"), timeout: 5)
        do {
            _ = try await cli.scan()
            Issue.record("expected a non-zero exit with no report to throw")
        } catch let error as DustlessError {
            guard case .exited(let status, let stderr) = error else {
                Issue.record("expected .exited, got \(error)")
                return
            }
            #expect(status == 3)
            #expect(stderr.contains("boom"))
        }
    }

    @Test func aHungEngineIsKilledAtTheDeadline() async throws {
        let cli = DustlessCLI(executable: try script("exec sleep 30"), timeout: 1)
        do {
            _ = try await cli.scan()
            Issue.record("expected the deadline to throw .timedOut")
        } catch let error as DustlessError {
            guard case .timedOut(let seconds) = error else {
                Issue.record("expected .timedOut, got \(error)")
                return
            }
            #expect(seconds == 1)
        }
    }

    private func recordingEngine(capture: URL, report: String = "{}", status: Int = 0) throws -> URL {
        try script(
            """
            d='\(capture.path)'
            printf '%s\\n' "$@" > "$d/argv"
            prev=''
            for a in "$@"; do
              if [ "$prev" = '--only-file' ]; then cat "$a" > "$d/selection.json"; fi
              prev="$a"
            done
            cat <<'DUSTLESS_EOF'
            \(report)
            DUSTLESS_EOF
            exit \(status)
            """
        )
    }

    private func captured(_ capture: URL, _ name: String) throws -> String {
        try String(contentsOf: capture.appendingPathComponent(name), encoding: .utf8)
    }

    private let applyReport = #"{"schemaVersion":2,"outcomes":[],"deletedBytes":0,"freed":0,"freeBefore":0,"freeAfter":0,"elapsedMs":1}"#

    @Test func theCleanCarriesExactlyTheSelectedPaths() async throws {
        let capture = try captureDir()
        let cli = DustlessCLI(
            executable: try recordingEngine(capture: capture, report: applyReport),
            timeout: 5
        )
        _ = try await cli.apply(only: ["/Users/me/.gradle/caches", "/Users/me/.npm/_cacache"])

        let argv = try captured(capture, "argv").split(separator: "\n").map(String.init)
        #expect(Array(argv.prefix(4)) == ["apply", "--json", "--yes", "--only-file"])
        #expect(argv.count == 5, "the flag takes one file argument, got \(argv)")
        let selection = argv[4]
        #expect(selection.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path), "\(selection)")
        #expect(try JSONDecoder().decode([String].self, from: Data(try captured(capture, "selection.json").utf8))
            == ["/Users/me/.gradle/caches", "/Users/me/.npm/_cacache"])
        #expect(!FileManager.default.fileExists(atPath: selection))
    }

    @Test func theSelectionFileIsRemovedWhenTheRunFails() async throws {
        let capture = try captureDir()
        let cli = DustlessCLI(
            executable: try recordingEngine(capture: capture, report: "boom", status: 3),
            timeout: 5
        )
        do {
            _ = try await cli.apply(only: ["/Users/me/.bun/install/cache"])
            Issue.record("expected the non-zero exit with no report to throw")
        } catch let error as DustlessError {
            guard case .exited(let status, _) = error else {
                Issue.record("expected .exited, got \(error)")
                return
            }
            #expect(status == 3)
        }
        let argv = try captured(capture, "argv").split(separator: "\n").map(String.init)
        #expect(argv.count == 5, "got \(argv)")
        let selection = argv[4]
        #expect(!FileManager.default.fileExists(atPath: selection))
    }

    @Test func theEngineErrorPayloadBecomesTheMessage() async throws {
        let cli = DustlessCLI(
            executable: try script("echo '{\"error\":\"cần một giá trị cho --only-file\"}'\nexit 1"),
            timeout: 5
        )
        do {
            _ = try await cli.apply(only: ["/a"])
            Issue.record("expected the refusal to throw")
        } catch let error as DustlessError {
            guard case .exited(let status, let detail) = error else {
                Issue.record("expected .exited, got \(error)")
                return
            }
            #expect(status == 1)
            #expect(detail.contains("--only-file"), "the engine's own reason, got \(detail)")
        }
    }

    private func captureDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dustless-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let purgedReport = #"""
    {"schemaVersion":2,"outcomes":[{"path":"/Applications/Test.app","status":"purged","bytes":2048,"detail":{"code":"purged"}}],
     "summary":{"trashed":0,"purged":1,"skipped":0,"failed":0,"totalBytes":2048}}
    """#

    private let failedPurgeReport = #"""
    {"schemaVersion":2,"outcomes":[{"path":"/Applications/Root.app","status":"failed","bytes":0,"detail":{"code":"io_error","params":{"code":"EACCES","message":"permission denied"}}}],
     "summary":{"trashed":0,"purged":0,"skipped":0,"failed":1,"totalBytes":0}}
    """#

    @Test func anUninstallAsksTheEngineToPurge() async throws {
        let capture = try captureDir()
        let cli = DustlessCLI(
            executable: try recordingEngine(capture: capture, report: purgedReport),
            timeout: 5
        )
        let report = try await cli.uninstallApp(path: "/Applications/Test.app", purge: true)

        let argv = try captured(capture, "argv").split(separator: "\n").map(String.init)
        #expect(argv == ["apps", "--uninstall", "/Applications/Test.app", "--confirm", "--json", "--purge"])
        #expect(report.outcomes.first?.status == .purged)
        #expect(report.summary.purged == 1)
    }

    @Test func anUninstallWithoutPurgeNeverAsksForIt() async throws {
        let capture = try captureDir()
        let cli = DustlessCLI(
            executable: try recordingEngine(capture: capture, report: purgedReport),
            timeout: 5
        )
        _ = try await cli.uninstallApp(path: "/Applications/Test.app")

        let argv = try captured(capture, "argv").split(separator: "\n").map(String.init)
        #expect(argv == ["apps", "--uninstall", "/Applications/Test.app", "--confirm", "--json"])
        #expect(!argv.contains("--purge"))
    }

    @Test func aRefusedPurgeSurfacesAsFailed() async throws {
        let capture = try captureDir()
        let cli = DustlessCLI(
            executable: try recordingEngine(capture: capture, report: failedPurgeReport, status: 1),
            timeout: 5
        )
        let report = try await cli.uninstallApp(path: "/Applications/Root.app", purge: true)

        let argv = try captured(capture, "argv").split(separator: "\n").map(String.init)
        #expect(argv.contains("--purge"), "the refusal is about the purge it refused: \(argv)")
        #expect(report.outcomes.map(\.status) == [.failed])
        #expect(report.summary.failed == 1)
        #expect(report.summary.trashed == 0, "never downgraded to the Trash")
        #expect(report.summary.purged == 0)
    }
}
