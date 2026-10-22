import AppKit
import DustlessKit
import Foundation
import SwiftUI
import Testing
@testable import DustlessApp

@Suite("engine failure paths", .serialized)
struct EngineFailureTests {
    private func temporaryHome() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dustless-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func bundleWithoutEngine() throws -> (context: BinarySearchContext, root: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dustless-missing-\(UUID().uuidString)", isDirectory: true)
        let resources = root
            .appendingPathComponent("Dustless.app/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("Dustless.app/Contents/MacOS/Dustless")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("engine".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let context = BinarySearchContext(
            roots: [resources, resources.appendingPathComponent("bin", isDirectory: true)],
            ownExecutable: executable
        )
        return (context, root)
    }

    @Test func theMissingEngineNamesEveryPathItSearched() throws {
        let bundle = try bundleWithoutEngine()
        defer { try? FileManager.default.removeItem(at: bundle.root) }

        var searched: [URL] = []
        do {
            _ = try BinaryLocator.locate(in: bundle.context)
            Issue.record("expected the missing engine to throw")
        } catch let error as BinaryLocationError {
            guard case .notFound(let paths) = error else {
                Issue.record("expected .notFound, got \(error)")
                return
            }
            searched = paths
        }
        #expect(!searched.isEmpty, "the error must name the paths it looked at")
        for language in Lang.allCases {
            let rendered = L10n.text(language, L10nText("errNotFound", [
                "list": searched.map(\.path).joined(separator: ", ")
            ]))
            for path in searched {
                #expect(
                    rendered.contains(path.path),
                    "the \(language.rawValue) message must name \(path.path)"
                )
            }
        }
    }

    @Test func theMissingEngineNeverRunsAnything() async throws {
        let bundle = try bundleWithoutEngine()
        defer { try? FileManager.default.removeItem(at: bundle.root) }
        let recorder = EngineCallRecorder()

        do {
            let cli = try DustlessCLI.resolve(context: bundle.context, launcher: recorder)
            _ = try await cli.scan()
            Issue.record("expected the missing engine to throw")
        } catch {
            #expect(error is BinaryLocationError)
        }
        #expect(await recorder.spawnCount == 0, "the app must not spawn anything without an engine")
    }

    @Test func theEngineExitingNonZeroIsReportedInEveryLanguage() async throws {
        let cli = DustlessCLI(
            executable: try FakeEngine.script(body: "echo 'boom' >&2\nexit 3"),
            timeout: 5,
            launcher: SandboxLauncher(home: try temporaryHome())
        )
        do {
            _ = try await cli.scan()
            Issue.record("expected the non-zero exit to throw")
        } catch let error as DustlessError {
            guard case .exited(let status, _) = error else {
                Issue.record("expected .exited, got \(error)")
                return
            }
            #expect(status == 3)
            for language in Lang.allCases {
                let rendered = L10n.text(language, error.localized)
                #expect(
                    rendered.contains("3"),
                    "the \(language.rawValue) message must name the exit status"
                )
                #expect(
                    !rendered.hasPrefix("reason."),
                    "the \(language.rawValue) message must not be a raw code"
                )
            }
        }
    }

    @Test func anUnreadablePayloadIsReportedInEveryLanguage() async throws {
        let cli = DustlessCLI(
            executable: try FakeEngine.script(body: "printf 'not json at all'"),
            timeout: 5,
            launcher: SandboxLauncher(home: try temporaryHome())
        )
        do {
            _ = try await cli.scan()
            Issue.record("expected the unreadable payload to throw")
        } catch let error as DustlessError {
            guard case .unreadableOutput = error else {
                Issue.record("expected .unreadableOutput, got \(error)")
                return
            }
            for language in Lang.allCases {
                let rendered = L10n.text(language, error.localized)
                #expect(
                    !rendered.isEmpty && rendered != error.localized.key,
                    "the \(language.rawValue) message must be a sentence, got \(rendered)"
                )
            }
        }
    }

    @Test func anUnsupportedSchemaVersionIsReported() async throws {
        let payload = """
        {"schemaVersion":12,"findings":[],"totals":{"green":{"count":0,"bytes":0},"yellow":{"count":0,"bytes":0},"red":{"count":0,"bytes":0},"blocked":{"count":0,"bytes":0}},"reclaimable":0,"freeBefore":0,"platform":"mac","scannedMs":1,"unscannable":[],"unscannableSummary":{"absent":0,"no_access":0,"not_supported":0,"error":0}}
        """
        let cli = DustlessCLI(
            executable: try FakeEngine.scriptPrinting(payload),
            timeout: 5,
            launcher: SandboxLauncher(home: try temporaryHome())
        )
        do {
            _ = try await cli.scan()
            Issue.record("the app must refuse a report it cannot understand")
        } catch let error as DustlessError {
            guard case .unreadableOutput(let reason) = error else {
                Issue.record("expected .unreadableOutput, got \(error)")
                return
            }
            #expect(
                reason.contains("12"),
                "the refusal must name the schema version the engine speaks, got \(reason)"
            )
            #expect(
                reason.contains("\(EngineContract.currentSchemaVersion)"),
                "the refusal must name the schema version the app understands, got \(reason)"
            )
        }
    }

    @Test func theEngineHangingPastTheDeadlineIsReported() async throws {
        let cli = DustlessCLI(
            executable: try FakeEngine.script(body: "exec sleep 30"),
            timeout: 1,
            launcher: SandboxLauncher(home: try temporaryHome())
        )
        do {
            _ = try await cli.scan()
            Issue.record("expected the deadline to throw")
        } catch let error as DustlessError {
            guard case .timedOut(let seconds) = error else {
                Issue.record("expected .timedOut, got \(error)")
                return
            }
            #expect(seconds == 1)
            for language in Lang.allCases {
                let rendered = L10n.text(language, error.localized)
                #expect(
                    rendered.contains("1"),
                    "the \(language.rawValue) message must name the deadline"
                )
            }
        }
    }

    @Test @MainActor func theAppReportsAMissingEngineAndKeepsItsNavigation() async throws {
        let store = ScanStore()
        let router = AppRouter()
        await store.rescan()

        #expect(store.engineError != nil, "a missing engine must set the error")
        #expect(store.report == nil, "a missing engine must not invent a report")
        #expect(store.phase == .idle, "a failed scan must leave the store idle")
        #expect(!store.isBusy, "a failed scan must not leave the store busy")
        #expect(!store.canClean, "nothing can be cleaned without a report")

        router.module = .cleanup
        #expect(router.module == .cleanup, "the navigation must survive an engine failure")
        #expect(store.engineError != nil, "the error must survive a navigation")
    }

    @Test @MainActor func theModuleStillRendersAfterTheEngineFails() async throws {
        let settings = TestData.settings(.en)
        let store = ScanStore()
        let router = AppRouter()
        router.module = .cleanup
        await store.rescan()
        #expect(store.engineError != nil)

        let pixels = try ScreenRender.buffer(
            of: ModuleContent(store: store, router: router, net: NetControl())
                .environmentObject(settings)
                .environmentObject(store),
            width: 900,
            height: 640
        )
        let bands = pixels.bands(mask: pixels.inkMask(), minimumInk: 1, gap: 3)
        #expect(bands.count >= 2, "the module must still draw after the engine failed")
        let orange = try ScreenRender.reference(.orange)
        #expect(
            pixels.count(matching: orange, tolerance: 45) > 8,
            "the engine error must be shown, not a blank screen"
        )
    }

    @Test @MainActor func theErrorStateOffersARetryThatIsNotBusy() async throws {
        let store = ScanStore()
        await store.rescan()
        #expect(store.engineError != nil)
        #expect(!store.isBusy, "the retry must be enabled when the app is not busy")
        #expect(store.dismissEngineError() == (), "dismissing the error must not throw")
        #expect(store.engineError == nil, "dismissing the error must clear it")
    }

    @Test @MainActor func aReportWithNoFindingsOffersNothingToDelete() throws {
        let totals = try decoded(TierTotals.self, "totals.json")
        let empty = ScanReport(
            findings: [],
            totals: totals,
            reclaimable: 0,
            freeBefore: 0,
            platform: "mac",
            scannedMs: 1,
            unscannable: [],
            unscannableSummary: UnscannableSummary(absent: 0, noAccess: 0, notSupported: 0, error: 0)
        )
        let store = ScanStore(preview: ScanStore.Preview(report: empty, scannedAt: Date()))
        #expect(store.report?.findings.isEmpty == true)
        #expect(store.selectedFindings.isEmpty)
        #expect(!store.canClean, "an empty report must offer no delete")
        store.selectAll(in: .safe)
        #expect(store.selection.isEmpty, "nothing can be selected when there is nothing")
    }

    @Test @MainActor func aReportWhereEverythingIsLockedOffersNothingToDelete() throws {
        let locked = try finding(tier: "yellow", blocked: true, bytes: 10, path: "/tmp/locked-one")
        let red = try finding(tier: "red", blocked: false, bytes: 20, path: "/tmp/red-one")
        let totals = try decoded(TierTotals.self, "totals.json")
        let report = ScanReport(
            findings: [locked, red],
            totals: totals,
            reclaimable: 0,
            freeBefore: 0,
            platform: "mac",
            scannedMs: 1,
            unscannable: [],
            unscannableSummary: UnscannableSummary(absent: 0, noAccess: 0, notSupported: 0, error: 0)
        )
        let store = ScanStore(preview: ScanStore.Preview(report: report, scannedAt: Date()))

        #expect(store.selectedFindings.isEmpty, "a locked item is never selected")
        #expect(!store.canClean, "a locked report offers no delete")

        store.toggle(locked)
        #expect(store.selection.isEmpty, "a locked item cannot be toggled into the selection")
        store.toggle(red)
        #expect(store.selection.isEmpty, "a red item cannot be toggled into the selection")

        store.selectAll(in: .locked)
        #expect(store.selection.isEmpty, "selecting all in the locked tab selects nothing")
        store.selectAll(in: .review)
        #expect(store.selection.isEmpty, "selecting all in the review tab selects nothing")

        #expect(store.selectedLockedCount == 2, "both locked items must be counted as locked")
    }
}
