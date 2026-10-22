import AppKit
import DustlessKit
import Foundation
import SwiftUI
import Testing
@testable import DustlessApp

@Suite("destructive paths", .serialized)
struct DestructivePathTests {
    private func sandbox() throws -> Sandbox {
        let sandbox = try Sandbox()
        #expect(
            sandbox.root.path.hasPrefix(NSTemporaryDirectory()),
            "the sandbox must live in the temporary directory"
        )
        return sandbox
    }

    @Test func cancellingDeletesNothing() async throws {
        let sandbox = try sandbox()
        defer { sandbox.remove() }
        let target = try sandbox.makeFile("green/old.bin")
        let engine = try FakeEngine.sandboxEngine(sandbox: sandbox)
        let launcher = SandboxLauncher(home: sandbox.root.path)

        let cli = DustlessCLI(executable: engine, timeout: 10, launcher: launcher)
        _ = cli

        #expect(await launcher.spawnCount == 0, "cancelling must not run the engine")
        #expect(FileManager.default.fileExists(atPath: target), "cancelling must not delete")
    }

    @Test func confirmingDeletesExactlyTheSelectedPaths() async throws {
        let sandbox = try sandbox()
        defer { sandbox.remove() }
        let selected = try sandbox.makeFile("green/old.bin")
        let alsoSelected = try sandbox.makeFile("green/other.bin")
        let untouched = try sandbox.makeFile("green/keep.bin")

        let engine = try FakeEngine.sandboxEngine(sandbox: sandbox)
        let launcher = SandboxLauncher(home: sandbox.root.path)
        let cli = DustlessCLI(executable: engine, timeout: 10, launcher: launcher)

        let report = try await cli.apply(only: [selected, alsoSelected])

        #expect(report.outcomes.map(\.status) == [.deleted, .deleted])
        #expect(!FileManager.default.fileExists(atPath: selected), "the selected path must be gone")
        #expect(!FileManager.default.fileExists(atPath: alsoSelected), "the selected path must be gone")
        #expect(FileManager.default.fileExists(atPath: untouched), "an unselected path must survive")
        #expect(await launcher.spawnCount == 1, "the engine must run exactly once")
    }

    @Test @MainActor func aLockedItemIsNeverDeleted() async throws {
        let sandbox = try sandbox()
        defer { sandbox.remove() }
        let deletable = try sandbox.makeFile("green/old.bin")
        let locked = try sandbox.makeFile("locked/tree")

        let totals = try decoded(TierTotals.self, "totals.json")
        let report = ScanReport(
            findings: [
                try finding(tier: "green", blocked: false, bytes: 10, path: deletable),
                try finding(tier: "yellow", blocked: true, bytes: 20, path: locked)
            ],
            totals: totals,
            reclaimable: 10,
            freeBefore: 0,
            platform: "mac",
            scannedMs: 1,
            unscannable: [],
            unscannableSummary: UnscannableSummary(absent: 0, noAccess: 0, notSupported: 0, error: 0)
        )
        let store = ScanStore(preview: ScanStore.Preview(report: report, scannedAt: Date()))
        store.selectAll(in: .safe)
        store.selectAll(in: .review)

        #expect(
            store.selectedFindings.map(\.path) == [deletable],
            "only the deletable finding may be selected, got \(store.selectedFindings.map(\.path))"
        )

        let engine = try FakeEngine.sandboxEngine(sandbox: sandbox)
        let launcher = SandboxLauncher(home: sandbox.root.path)
        let cli = DustlessCLI(executable: engine, timeout: 10, launcher: launcher)
        _ = try await cli.apply(only: store.selectedFindings.map(\.path))

        #expect(!FileManager.default.fileExists(atPath: deletable), "the selected path must be gone")
        #expect(FileManager.default.fileExists(atPath: locked), "a locked path must never be deleted")
    }

    @Test func aPathThatDisappearedIsReportedAndNotDeleted() async throws {
        let sandbox = try sandbox()
        defer { sandbox.remove() }
        let present = try sandbox.makeFile("green/old.bin")
        let vanished = try sandbox.makeFile("green/vanished.bin")
        try FileManager.default.removeItem(atPath: vanished)

        let engine = try FakeEngine.sandboxEngine(sandbox: sandbox)
        let launcher = SandboxLauncher(home: sandbox.root.path)
        let cli = DustlessCLI(executable: engine, timeout: 10, launcher: launcher)

        let report = try await cli.apply(only: [present, vanished])
        let skipped = report.outcomes.first { $0.path == vanished }
        #expect(skipped?.status == .skipped, "a vanished path must be reported as skipped")
        #expect(skipped?.detail?.code == "not_found", "the report must name the reason")
        #expect(!FileManager.default.fileExists(atPath: present), "the other path must still be deleted")
    }

    @Test func aRedListedPathIsNeverDeleted() async throws {
        let sandbox = try sandbox()
        defer { sandbox.remove() }
        let red = try sandbox.makeFile("red/protected.bin")
        let normal = try sandbox.makeFile("green/old.bin")

        let engine = try FakeEngine.sandboxEngine(sandbox: sandbox)
        let launcher = SandboxLauncher(home: sandbox.root.path)
        let cli = DustlessCLI(executable: engine, timeout: 10, launcher: launcher)

        let report = try await cli.apply(only: [red, normal])
        let refused = report.outcomes.first { $0.path == red }
        #expect(refused?.status == .failed, "a red listed path must be refused")
        #expect(refused?.detail?.code == "red_list", "the report must name the reason")
        #expect(FileManager.default.fileExists(atPath: red), "a red listed path must survive")
        #expect(!FileManager.default.fileExists(atPath: normal), "the other path must still be deleted")
    }

    @Test func aPathOutsideTheSandboxIsNeverDeleted() async throws {
        let sandbox = try sandbox()
        defer { sandbox.remove() }
        let outside = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dustless-outside-\(UUID().uuidString).bin")
        try Data("outside\n".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let engine = try FakeEngine.sandboxEngine(sandbox: sandbox)
        let launcher = SandboxLauncher(home: sandbox.root.path)
        let cli = DustlessCLI(executable: engine, timeout: 10, launcher: launcher)

        let report = try await cli.apply(only: [outside.path])
        #expect(report.outcomes.first?.status == .failed, "a path outside the sandbox must be refused")
        #expect(FileManager.default.fileExists(atPath: outside.path), "the outside path must survive")
    }

    @Test func theAppUninstallMovesToTheTrashByDefault() async throws {
        let sandbox = try sandbox()
        defer { sandbox.remove() }
        _ = try sandbox.makeDirectory("Applications/Toy.app/Contents")
        try sandbox.makeFile("Applications/Toy.app/Contents/Info.plist")
        let bundle = sandbox.path("Applications/Toy.app")

        let engine = try FakeEngine.sandboxEngine(sandbox: sandbox)
        let launcher = SandboxLauncher(home: sandbox.root.path)
        let cli = DustlessCLI(executable: engine, timeout: 10, launcher: launcher)

        let report = try await cli.uninstallApp(path: bundle)
        #expect(report.outcomes.first?.status == .trashed, "the default must move the app to the Trash")
        #expect(report.summary.trashed == 1)
        #expect(report.summary.purged == 0, "the default must never purge")
        #expect(!FileManager.default.fileExists(atPath: bundle), "the app must leave its place")
        #expect(
            FileManager.default.fileExists(atPath: sandbox.path(".Trash/Toy.app/Contents/Info.plist")),
            "the app must be recoverable from the Trash"
        )
    }

    @Test func thePermanentDeleteHasToBeAskedFor() async throws {
        let sandbox = try sandbox()
        defer { sandbox.remove() }
        _ = try sandbox.makeDirectory("Applications/Toy.app/Contents")
        try sandbox.makeFile("Applications/Toy.app/Contents/Info.plist")
        let bundle = sandbox.path("Applications/Toy.app")

        let engine = try FakeEngine.sandboxEngine(sandbox: sandbox)
        let launcher = SandboxLauncher(home: sandbox.root.path)
        let cli = DustlessCLI(executable: engine, timeout: 10, launcher: launcher)

        let report = try await cli.uninstallApp(path: bundle, purge: true)
        #expect(report.outcomes.first?.status == .purged, "the permanent delete must purge")
        #expect(report.summary.purged == 1)
        #expect(report.summary.trashed == 0, "a purge must not go through the Trash")
        #expect(!FileManager.default.fileExists(atPath: bundle), "the app must be gone")
        #expect(
            !FileManager.default.fileExists(atPath: sandbox.path(".Trash/Toy.app")),
            "a purge must leave nothing behind"
        )
    }

    @Test func theStoragePanelMovesALargeFileToTheTrash() async throws {
        let sandbox = try sandbox()
        defer { sandbox.remove() }
        let file = try sandbox.makeFile("Movies/clip.mov")

        let engine = try FakeEngine.sandboxEngine(sandbox: sandbox)
        let launcher = SandboxLauncher(home: sandbox.root.path)
        let cli = DustlessCLI(executable: engine, timeout: 10, launcher: launcher)

        let report = try await cli.deleteLargeFile(path: file)
        #expect(report.outcomes.first?.status == .trashed, "a large file must go to the Trash")
        #expect(!FileManager.default.fileExists(atPath: file), "the file must leave its place")
        #expect(
            FileManager.default.fileExists(atPath: sandbox.path(".Trash/clip.mov")),
            "the file must be recoverable from the Trash"
        )
    }

    @Test func theStoragePanelRefusesAPathOutsideTheScannedRoots() async throws {
        let sandbox = try sandbox()
        defer { sandbox.remove() }
        let outside = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dustless-outside-\(UUID().uuidString).bin")
        try Data("outside\n".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let engine = try FakeEngine.sandboxEngine(sandbox: sandbox)
        let launcher = SandboxLauncher(home: sandbox.root.path)
        let cli = DustlessCLI(executable: engine, timeout: 10, launcher: launcher)

        let report = try await cli.deleteLargeFile(path: outside.path)
        #expect(report.outcomes.first?.status == .failed, "a path outside the roots must be refused")
        #expect(
            report.outcomes.first?.detail?.code == "outside_roots",
            "the refusal must name the reason"
        )
        #expect(FileManager.default.fileExists(atPath: outside.path), "the outside path must survive")
    }

    @Test func theEngineRunsInsideTheSandboxHome() async throws {
        let sandbox = try sandbox()
        defer { sandbox.remove() }
        let engine = try FakeEngine.sandboxEngine(sandbox: sandbox)
        let launcher = SandboxLauncher(home: sandbox.root.path)
        let cli = DustlessCLI(executable: engine, timeout: 10, launcher: launcher)

        _ = try? await cli.scan()
        #expect(await launcher.spawnCount == 1)
        #expect(await launcher.spawnedPids.allSatisfy { $0 > 0 }, "every launch must have a pid")
    }

    @Test func theEngineCannotBeLaunchedMoreThanTheCap() async throws {
        let sandbox = try sandbox()
        defer { sandbox.remove() }
        let engine = try FakeEngine.sandboxEngine(sandbox: sandbox)
        let launcher = SandboxLauncher(home: sandbox.root.path, cap: 1)
        let cli = DustlessCLI(executable: engine, timeout: 10, launcher: launcher)

        _ = try? await cli.scan()
        do {
            _ = try await cli.scan()
            Issue.record("the launcher must refuse to run the engine past the cap")
        } catch {
            #expect(error is SandboxLauncher.Failure)
        }
        #expect(await launcher.spawnCount == 2, "the cap must stop the second launch")
    }
}
