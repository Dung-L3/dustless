import Testing
import Foundation
import DustlessKit

private let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
private let fixtures = here.appendingPathComponent("Fixtures")

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtures.appendingPathComponent(name))
}

@Suite("disk space model")
struct DiskSpaceTests {
    @Test func homeVolumeReturnsValidValues() {
        let space = DiskSpace.homeVolume()
        #expect(space != nil, "home volume should be available")
        if let space {
            #expect(space.total > 0, "total should be positive")
            #expect(space.available >= 0, "available should not be negative")
            #expect(space.used >= 0, "used should not be negative")
            #expect(space.used + space.available == space.total, "used + available == total")
        }
    }

    @Test func manualInitInvariantsHold() {
        let space = DiskSpace(volumeName: "Test", total: 1000, used: 300, available: 700)
        #expect(space.total == 1000)
        #expect(space.used == 300)
        #expect(space.available == 700)
        #expect(space.free == 700)
        #expect(space.used + space.available == space.total)
    }

    @Test func zeroAvailableEdgeCase() {
        let space = DiskSpace(volumeName: "Test", total: 1000, used: 1000, available: 0)
        #expect(space.used + space.available == space.total)
    }

    @Test func fullAvailableEdgeCase() {
        let space = DiskSpace(volumeName: "Test", total: 1000, used: 0, available: 1000)
        #expect(space.used + space.available == space.total)
    }
}

private func findingJSON(
    tier: String, blocked: Bool, bytes: UInt64, path: String = "/tmp/x"
) -> Data {
    Data("""
    {"ruleId":"r","tier":"\(tier)","desc":"d","path":"\(path)","bytes":\(bytes),
     "mtime":0,"atime":0,"ageDays":10,"verified":\(!blocked),"blocked":\(blocked),"note":""}
    """.utf8)
}

private func finding(
    tier: String, blocked: Bool, bytes: UInt64, path: String = "/tmp/x"
) throws -> Finding {
    try JSONDecoder().decode(Finding.self, from: findingJSON(tier: tier, blocked: blocked, bytes: bytes, path: path))
}

@Suite("engine payload contract")
struct EngineContractTests {
    @Test func decodesRealScanPayload() throws {
        let report = try JSONDecoder().decode(ScanReport.self, from: fixture("scan.json"))
        #expect(!report.findings.isEmpty)
        #expect(report.reclaimable > 0)
        #expect(report.freeBefore > 0)
        #expect(report.platform == "mac")
    }

    @Test func decodesRealApplyPayload() throws {
        let report = try JSONDecoder().decode(ApplyReport.self, from: fixture("apply.json"))
        #expect(report.freeBefore >= 0)
        #expect(report.freeAfter >= 0)
        #expect(report.elapsedMs >= 0)
    }

    @Test func decodesRealRamPayload() throws {
        let report = try JSONDecoder().decode(MemoryReport.self, from: fixture("ram.json"))
        #expect(report.memory.total > 0)
        #expect(report.memory.used > 0)
        #expect(report.memory.available > 0)
        #expect(report.memory.swapUsed > 0)
        #expect(report.memory.pressurePercent >= 0 && report.memory.pressurePercent <= 100)
        #expect(!report.processes.isEmpty)
        #expect(report.processes.allSatisfy { $0.mem > 0 })
    }

    @Test func rejectsMalformedScanPayload() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ScanReport.self, from: Data(#"{"findings":"nope"}"#.utf8))
        }
    }

    @Test func rejectsPayloadMissingRequiredFields() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ScanReport.self, from: Data(#"{"findings":[]}"#.utf8))
        }
    }

    @Test func rejectsUnknownTierRatherThanGuessing() {
        #expect(throws: (any Error).self) {
            try finding(tier: "purple", blocked: false, bytes: 1)
        }
    }

    @Test func tierCoversEverySafetyLevel() {
        #expect(Tier.allCases.count == 4)
        #expect(Tier(rawValue: "blocked") != nil)
        #expect(Tier(rawValue: "red") != nil)
        #expect(Tier(rawValue: "green") != nil)
        #expect(Tier(rawValue: "yellow") != nil)
    }
}

@Suite("safety invariants")
struct SafetyInvariantTests {
    @Test func blockedFindingIsNeverDeletable() throws {
        #expect(try finding(tier: "yellow", blocked: true, bytes: 1024).isDeletableByEngine == false)
    }

    @Test func redFindingIsNeverDeletable() throws {
        #expect(try finding(tier: "red", blocked: false, bytes: 1024).isDeletableByEngine == false)
    }

    @Test func greenFindingIsDeletable() throws {
        #expect(try finding(tier: "green", blocked: false, bytes: 1024).isDeletableByEngine)
    }

    @Test func blockedBytesAreExcludedFromTheDeletableSet() throws {
        let green = try finding(tier: "green", blocked: false, bytes: 100, path: "/a")
        let blocked = try finding(tier: "yellow", blocked: true, bytes: 900, path: "/b")
        #expect(green.isDeletableByEngine)
        #expect(!blocked.isDeletableByEngine)
        #expect(green.bytes + blocked.bytes == 1000)
    }

    @Test func distinctPathsStayDistinctFindings() throws {
        let a = try finding(tier: "green", blocked: false, bytes: 1, path: "/a")
        let b = try finding(tier: "green", blocked: false, bytes: 1, path: "/b")
        #expect(a != b)
        #expect(a.id != b.id)
    }

    @Test func decodedScanExposesDeletableAndLockedSets() throws {
        let report = try JSONDecoder().decode(ScanReport.self, from: fixture("scan.json"))
        let deletable = report.deletable
        #expect(deletable.allSatisfy { $0.isDeletableByEngine })
        #expect(deletable.count <= report.findings.count)
    }

    @Test func aFreshScanNeverPreSelectsAnything() throws {
        let report = try JSONDecoder().decode(ScanReport.self, from: fixture("scan.json"))
        // The fixture has deletable findings, so an empty selection is a real
        // decision and not an artefact of an empty report.
        #expect(!report.deletable.isEmpty)
        #expect(report.initialSelection.isEmpty)
    }
}

@Suite("byte formatting")
struct ByteFormatTests {
    @Test func boundariesAreExact() {
        #expect(ByteFormat.string(0) == "0 B")
        #expect(ByteFormat.string(1023) == "1023 B")
        #expect(ByteFormat.string(1024) == "1.0 KB")
        #expect(ByteFormat.string(1_048_576) == "1.0 MB")
        #expect(ByteFormat.string(1_073_741_824) == "1.0 GB")
    }

    @Test(arguments: [UInt64(0), 1, 999, 1023, 1024, 1025, 1_048_575, 1_048_576, 1_099_511_627_776])
    func neverProducesNaNOrEmptyOrNegative(_ value: UInt64) {
        let text = ByteFormat.string(value)
        #expect(!text.isEmpty, "empty for \(value)")
        #expect(!text.lowercased().contains("nan"), "NaN for \(value)")
        #expect(!text.contains("-"), "negative for \(value)")
    }

    @Test func veryLargeValueStaysReadable() {
        let text = ByteFormat.string(5_000_000_000_000_000_000)
        #expect(text.contains("TB") || text.contains("PB"))
    }
}

@Suite("apps model")
struct AppsModelTests {
    @Test func decodesInstalledAppList() throws {
        let apps = try JSONDecoder().decode([InstalledApp].self, from: fixture("apps.json"))
        #expect(apps.count == 3)
        let first = try #require(apps.first)
        #expect(!first.name.isEmpty)
        #expect(first.path.hasSuffix(".app"))
        #expect(!first.bundleId.isEmpty)
        #expect(first.bytes > 0)
        #expect(first.relatedPaths.allSatisfy { $0.hasPrefix("/") || $0.hasPrefix("~") })
    }

    @Test func installedAppsSortByBytesDescending() throws {
        let apps = try JSONDecoder().decode([InstalledApp].self, from: fixture("apps.json"))
        let bytes = apps.map(\.bytes).sorted(by: >)
        #expect(apps.sorted { $0.bytes > $1.bytes }.map(\.bytes) == bytes)
    }

    @Test func decodesUninstallReport() throws {
        let report = try JSONDecoder().decode(UninstallReport.self, from: fixture("uninstall.json"))
        #expect(report.outcomes.count == 3)
        #expect(report.outcomes[0].status == .trashed)
        #expect(report.outcomes[2].status == .skipped)
        // The summary counters are item counts, not bytes.
        #expect(report.summary.trashed == 2)
        #expect(report.summary.purged == 0)
        #expect(report.summary.skipped == 1)
        #expect(report.summary.failed == 0)
        #expect(report.summary.totalBytes == 133942549)
    }

    @Test func uninstallStatusCoversAllCases() {
        #expect(UninstallOutcome.Status.allCases.count == 4)
        #expect(UninstallOutcome.Status(rawValue: "trashed") != nil)
        #expect(UninstallOutcome.Status(rawValue: "purged") != nil)
        #expect(UninstallOutcome.Status(rawValue: "skipped") != nil)
        #expect(UninstallOutcome.Status(rawValue: "failed") != nil)
    }

    @Test func rejectsMalformedAppsPayload() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([InstalledApp].self, from: Data(#"{"bundleId":"nope"}"#.utf8))
        }
    }

    @Test func rejectsMalformedUninstallReport() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(UninstallReport.self, from: Data(#"{"outcomes":"nope"}"#.utf8))
        }
    }
}

/// The panel filters. The rule is that the haystack is whatever a person who
/// knows the machine would actually type: a bundle id, a folder, a helper
/// process name, or a pid.
@Suite("panel filters")
struct PanelFilterTests {
    private func installedApp(name: String, bundleId: String, path: String) -> InstalledApp {
        InstalledApp(bundleId: bundleId, name: name, path: path, bytes: 1, relatedPaths: [])
    }

    @Test func anAppIsFoundByNameBundleIdOrPath() {
        let app = installedApp(
            name: "Visual Studio Code",
            bundleId: "com.microsoft.VSCode",
            path: "/Applications/Visual Studio Code.app"
        )
        #expect(app.matches("visual studio"))
        #expect(app.matches("microsoft.vscode"))
        #expect(app.matches("/applications/"))
        #expect(!app.matches("firefox"))
    }

    @Test func noNeedleMeansNoFilter() throws {
        let app = installedApp(name: "Anything", bundleId: "x", path: "/x")
        #expect(app.matches(""))
        let files = try JSONDecoder().decode([LargeFile].self, from: fixture("largefiles.json"))
        #expect(files.allSatisfy { $0.matches("") })
        let group = try #require(try [process(command: "/usr/bin/x")].groupedByApp().first)
        #expect(group.matches(""))
        #expect(group.contains(category: .other))
    }

    @Test func aFileIsFoundByNameOrFolder() throws {
        let files = try JSONDecoder().decode([LargeFile].self, from: fixture("largefiles.json"))
        let file = try #require(files.first { $0.name == "screen recording.mov" })
        #expect(file.matches("screen recording"))
        #expect(file.matches((file.path as NSString).deletingLastPathComponent.lowercased()))
        #expect(!file.matches("a name that is in no folder of this list"))
    }

    /// The case the grouped list gets wrong on its own: the thing that eats the
    /// memory is a helper, not the application name the group is labelled with.
    @Test func aGroupIsFoundByAHelperProcessNameToo() throws {
        let renderer = "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Helpers/Brave Browser Helper (Renderer) --type=renderer"
        let groups = try [process(command: renderer, mem: 900, pid: 4242)].groupedByApp()

        let group = try #require(groups.first)
        #expect(group.matches("brave browser"))
        #expect(group.matches("brave browser.app"))
        #expect(group.matches("(renderer)"))
        #expect(group.matches("4242"))
        // A pid is an exact identifier, not a fragment: 42 is not 4242.
        #expect(!group.matches("42"))
        #expect(!group.matches("safari"))
    }

    @Test func aGroupJoinsTheCategoryOfAnyProcessItOwns() throws {
        let browser = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
        let groups = try [
            process(command: browser, mem: 10, pid: 1),
            process(command: "/usr/libexec/thingd", mem: 5, pid: 2),
        ].groupedByApp()

        #expect(groups.count == 2)
        // Every fixture process is reported as `other`, which is the point: a
        // category filter must not silently drop a group.
        #expect(groups.allSatisfy { $0.contains(category: .other) })
        #expect(groups.allSatisfy { !$0.contains(category: .browser) })
    }
}

/// Avoid collision with Foundation.NSProcessInfo, as the Memory view does.
private typealias MemProcess = DustlessKit.ProcessInfo

/// Builds the payload shape the engine reports, the same way the model tests
/// above build their findings. The command is the only field grouping reads.
private func process(command: String, mem: UInt64 = 1, pid: Int = 1) throws -> MemProcess {
    let executable = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
    let name = executable.split(separator: "/").last.map(String.init) ?? executable
    return try JSONDecoder().decode(MemProcess.self, from: Data("""
    {"pid":\(pid),"ppid":0,"name":"\(name)","command":"\(command)","cpu":0,"mem":\(mem),
     "owner":"me","root":false,"category":"other"}
    """.utf8))
}

@Suite("process grouping")
struct ProcessGroupTests {
    /// The rule under test: the first `.app` bundle in the command owns the
    /// process. Twelve Brave helpers must land in one group, not twelve.
    @Test func helpersJoinTheirApplicationBundle() throws {
        let brave = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
        let renderer = "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/155/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer) --type=renderer"
        let groups = try [process(command: brave, mem: 100), process(command: renderer, mem: 50)]
            .groupedByApp()

        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.id == "/Applications/Brave Browser.app")
        #expect(group.bundlePath == "/Applications/Brave Browser.app")
        #expect(group.label == "Brave Browser")
        #expect(group.count == 2)
        #expect(group.bytes == 150)
    }

    /// The bundle is found between `/` boundaries, not by splitting on
    /// whitespace: a space in the application name is what breaks the engine's
    /// own `name` field.
    @Test func bundleNamesMayContainSpaces() throws {
        let groups = try [process(command: "/Users/me/Apps/My Cool App.app/Contents/MacOS/cool")]
            .groupedByApp()
        #expect(groups.first?.label == "My Cool App")
        #expect(groups.first?.id == "/Users/me/Apps/My Cool App.app")
    }

    @Test func processesWithoutABundleGroupOnTheirExecutable() throws {
        let groups = try [
            process(command: "/usr/libexec/thingd --daemon"),
            process(command: "/usr/libexec/thingd -v"),
            process(command: "/usr/sbin/cron"),
            process(command: "node server.js"),
        ].groupedByApp()

        #expect(groups.count == 3)
        #expect(groups.allSatisfy { $0.bundlePath == nil })
        let thingd = try #require(groups.first { $0.label.hasPrefix("/usr/libexec/thingd") })
        #expect(thingd.count == 2)
        #expect(thingd.label == "/usr/libexec/thingd", "no bundle, so the path is the label")
        #expect(groups.contains { $0.label == "node" })
    }

    /// ".apple" and ".xpc" paths are not bundles; a stray mention in an argument
    /// is not either.
    @Test func thingsThatMerelyEndInAppAreNotBundles() throws {
        let groups = try [
            process(command: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/WebContent"),
            process(command: "/usr/bin/mapper --out=/tmp/report.app"),
        ].groupedByApp()

        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.bundlePath == nil })
        #expect(groups.contains { $0.label == "/usr/bin/mapper" })
    }

    @Test func groupsSortByTotalMemoryNotByTheirBiggestProcess() throws {
        let groups = try [
            process(command: "/usr/bin/small", mem: 100),
            process(command: "/usr/bin/one", mem: 10),
            process(command: "/usr/bin/two", mem: 10),
            process(command: "/usr/bin/three", mem: 10),
        ].groupedByApp()

        #expect(groups.map(\.bytes) == [100, 10, 10, 10])
        #expect(groups.first?.bytes == 100)
        #expect(groups.last?.bytes == 10)
    }

    /// Same total, two groups: the order must be by key, or the list reshuffles
    /// between two refreshes of the same report.
    @Test func tiesBreakOnTheGroupKey() throws {
        let procs = try [process(command: "/usr/bin/b"), process(command: "/usr/bin/a", pid: 2)]
        #expect(procs.groupedByApp().map(\.id) == ["/usr/bin/a", "/usr/bin/b"])
    }

    @Test func groupMembersAreSortedBiggestFirst() throws {
        // Same executable, different pids: without a bundle the rule groups on
        // the executable path, so these are ONE group.
        let group = try #require(try [
            process(command: "/usr/bin/a", mem: 1, pid: 1),
            process(command: "/usr/bin/a", mem: 9, pid: 2),
            process(command: "/usr/bin/a", mem: 5, pid: 3),
        ].groupedByApp().first)
        #expect(group.processes.map(\.mem) == [9, 5, 1])
    }

    @Test func everyProcessLandsInExactlyOneGroup() throws {
        let procs = try (0..<20).map { try process(command: "/usr/bin/p\($0 % 4)", mem: UInt64($0), pid: $0) }
        let groups = procs.groupedByApp()
        let bytes = groups.reduce(UInt64(0)) { $0 + $1.bytes }
        #expect(groups.count == 4)
        #expect(groups.reduce(0) { $0 + $1.count } == procs.count)
        #expect(bytes == procs.reduce(UInt64(0)) { $0 + $1.mem })
        #expect(Set(groups.flatMap(\.processes)).count == procs.count)
    }

    @Test func noProcessesIsNoGroups() {
        let none: [MemProcess] = []
        #expect(none.groupedByApp().isEmpty)
    }

    /// The two opencode rows in the fixture have different executables — one
    /// absolute, one from a PATH — so they stay apart. Everything else must
    /// survive the grouping untouched.
    @Test func groupingNeverLosesAnythingFromTheRealPayload() throws {
        let report = try JSONDecoder().decode(MemoryReport.self, from: fixture("ram.json"))
        let groups = report.processes.groupedByApp()

        #expect(groups.reduce(UInt64(0)) { $0 + $1.bytes } == report.processes.reduce(UInt64(0)) { $0 + $1.mem })
        #expect(Set(groups.flatMap(\.processes)) == Set(report.processes))
        #expect(groups.map(\.bytes) == groups.map(\.bytes).sorted(by: >))
        // The bundled process in the payload resolves to its bundle, not to the
        // truncated name the engine reports.
        #expect(groups.contains { $0.bundlePath == "/Applications/Stremio.app" && $0.label == "Stremio" })
    }
}

@Suite("largest files model")
struct LargeFilesModelTests {
    @Test func decodesLargeFileList() throws {
        let files = try JSONDecoder().decode([LargeFile].self, from: fixture("largefiles.json"))
        #expect(files.count == 3)
        let first = try #require(files.first)
        #expect(first.name == "screen recording.mov")
        #expect(first.path.hasPrefix("/"))
        #expect(first.size == 4_823_449_600)
        // Milliseconds, like every other mtime the engine reports.
        #expect(abs(first.modified.timeIntervalSince1970 - 1_680_674_828) < 1)
        #expect(files.allSatisfy { $0.size > 0 })
    }

    @Test func largeFilesSortBySizeDescending() throws {
        let files = try JSONDecoder().decode([LargeFile].self, from: fixture("largefiles.json"))
        let sizes = files.map(\.size).sorted(by: >)
        #expect(files.sorted { $0.size > $1.size }.map(\.size) == sizes)
    }

    @Test func distinctPathsStayDistinctFiles() throws {
        let files = try JSONDecoder().decode([LargeFile].self, from: fixture("largefiles.json"))
        #expect(Set(files.map(\.path)).count == files.count)
        #expect(Set(files.map(\.id)).count == files.count)
    }

    @Test func rejectsMalformedLargeFilePayload() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([LargeFile].self, from: Data(#"[{"size":1}]"#.utf8))
        }
    }

    @Test func rejectsFileWithoutSize() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([LargeFile].self, from: Data(#"[{"path":"/a","mtime":0}]"#.utf8))
        }
    }
}

@Suite("awdl model")
struct AwdlModelTests {
    @Test func decodesAStatusReport() throws {
        let report = try JSONDecoder().decode(AwdlReport.self, from: fixture("awdl.json"))
        #expect(report.platform == "mac")
        #expect(report.interface == "awdl0")
        #expect(report.state == .on)
        #expect(report.changed == false)
        #expect(report.outcome == nil, "a read-only status call carries no outcome")
    }

    /// The rule must grant exactly the two ifconfig commands: a wildcard here
    /// would widen what the password-free toggle is allowed to run.
    @Test func thePrivilegeRuleIsScopedToTwoExactCommands() throws {
        let privilege = try JSONDecoder().decode(AwdlPrivilege.self, from: fixture("awdl-privilege.json"))
        #expect(privilege.path == "/etc/sudoers.d/dustless-awdl")
        #expect(privilege.allowed == ["/sbin/ifconfig awdl0 down", "/sbin/ifconfig awdl0 up"])
        #expect(privilege.rule.contains("NOPASSWD:"))
        #expect(!privilege.rule.contains("*"))
        #expect(privilege.rule.contains(privilege.allowed[0]))
        #expect(privilege.rule.contains(privilege.allowed[1]))
    }

    @Test func thePrivilegeFileNameHasNoDotWhichSudoWouldIgnore() throws {
        let privilege = try JSONDecoder().decode(AwdlPrivilege.self, from: fixture("awdl-privilege.json"))
        #expect(privilege.path.split(separator: "/").last?.contains(".") == false)
        #expect(privilege.rule.hasSuffix("\n"))
    }

    @Test func decodesAToggleOutcome() throws {
        let ran = try JSONDecoder().decode(AwdlReport.self, from: Data(#"""
        {"platform":"mac","interface":"awdl0","state":"off","changed":true,"outcome":{"status":"ran","detail":"awdl0 down"}}
        """#.utf8))
        #expect(ran.state == .off)
        #expect(ran.changed)
        #expect(ran.outcome?.status == .ran)

        let refused = try JSONDecoder().decode(AwdlReport.self, from: Data(#"""
        {"platform":"mac","interface":"awdl0","state":"on","changed":false,"outcome":{"status":"refused","detail":"needs root"}}
        """#.utf8))
        #expect(refused.outcome?.status == .refused)
        #expect(refused.changed == false)
    }

    @Test func notApplicableKeepsItsHyphenatedWireValue() throws {
        let report = try JSONDecoder().decode(AwdlReport.self, from: Data(#"""
        {"platform":"linux","interface":null,"state":"absent","changed":false,"outcome":{"status":"not-applicable","detail":"macOS only"}}
        """#.utf8))
        #expect(report.interface == nil)
        #expect(report.state == .absent)
        #expect(report.outcome?.status == .notApplicable)
    }

    @Test func rejectsAnUnknownStateRatherThanGuessing() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AwdlReport.self, from: Data(#"{"platform":"mac","state":"maybe","changed":false}"#.utf8))
        }
    }
}

/// The run helper must treat the engine's non-zero exit as data, not as the
/// error: the engine prints a complete report and *then* exits 1 whenever an
/// outcome failed or was refused. Its deadline must also actually fire, or a
/// hung engine would hang the app forever.
@Suite("engine process contract")
struct EngineProcessContractTests {
    /// Writes a throwaway executable shell script and returns its URL. The test
    /// target ships no bundle resources, so the script is created on disk.
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
        // The real scan fixture, printed whole, then exit 1 — the exact shape of
        // a partially-failed clean or a refused toggle.
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
        // `exec` replaces the shell with sleep, so SIGTERM reaches sleep itself
        // and the run cannot outlive the deadline.
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
}

/// The network panel decodes what `src/core/net/index.ts` prints. The status
/// values are a wire contract: an unknown one must fail the decode rather than
/// be guessed at, or a new engine status would silently render as nothing.
@Suite("network model")
struct NetModelTests {
    @Test func decodesAReportWithAnOutcome() throws {
        let report = try JSONDecoder().decode(NetReport.self, from: fixture("net.json"))
        #expect(report.platform == "mac")
        #expect(report.iface == "en0")
        #expect(report.gateway == "192.168.1.1")
        #expect(report.dns == ["1.1.1.1", "1.0.0.1", "8.8.8.8"])
        #expect(report.soloRoute)
        let outcome = try #require(report.outcome(for: "reset-dns"))
        #expect(outcome.status == .ran)
        #expect(outcome.before == "1.1.1.1, 1.0.0.1")
        #expect(outcome.after == "DHCP-provided values")
        #expect(outcome.needsAttention == false)
    }

    @Test func decodesAReadOnlyReportWithNoRoute() throws {
        let report = try JSONDecoder().decode(NetReport.self, from: Data(#"""
        {"platform":"linux","iface":null,"gateway":null,"dns":[],"soloRoute":false,"outcomes":[]}
        """#.utf8))
        #expect(report.iface == nil)
        #expect(report.gateway == nil)
        #expect(report.outcomes.isEmpty)
        #expect(report.outcome(for: "flush-dns") == nil)
    }

    @Test func notApplicableKeepsItsHyphenatedWireValue() throws {
        let report = try JSONDecoder().decode(NetReport.self, from: Data(#"""
        {"platform":"mac","iface":"en0","gateway":"1.1.1.1","dns":[],"soloRoute":true,"outcomes":[{"op":"flush-routing","status":"not-applicable","detail":"no route cache"}]}
        """#.utf8))
        #expect(report.outcomes.first?.status == .notApplicable)
    }

    @Test func aRefusalIsNotAFailure() throws {
        let report = try JSONDecoder().decode(NetReport.self, from: Data(#"""
        {"platform":"mac","iface":"en0","gateway":"1.1.1.1","dns":[],"soloRoute":true,"outcomes":[{"op":"renew-dhcp","status":"refused","detail":"needs root"}]}
        """#.utf8))
        #expect(report.outcomes.first?.needsAttention == true)
    }

    @Test func anUnknownStatusThrowsRatherThanGuessing() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(NetReport.self, from: Data(#"""
            {"platform":"mac","iface":null,"gateway":null,"dns":[],"soloRoute":true,"outcomes":[{"op":"x","status":"maybe","detail":""}]}
            """#.utf8))
        }
    }

    /// The panel prints `settings.t(op.labelKey)` and `op.helpKey`; a key missing
    /// from a table would render as the raw key, so this pins all three.
    @Test func everyOfferedOperationIsTranslatedInEveryLanguage() {
        for op in NetOp.allCases {
            for lang in Lang.allCases {
                let table = L10n.table(lang)
                #expect(table[op.labelKey] != nil, "\(lang)/\(op.labelKey)")
                #expect(table[op.helpKey] != nil, "\(lang)/\(op.helpKey)")
            }
        }
    }

    @Test func theOfferedSetMatchesTheEngine() {
        // flush-routing is macOS-refused by design, so the app must not offer it.
        #expect(NetOp(rawValue: "flush-routing") == nil)
        #expect(NetOp.allCases.count == 5)
        #expect(NetOp.flushDns.isAdvanced == false)
        #expect(NetOp.allCases.filter(\.isAdvanced).count == NetOp.allCases.count - 1)
        // The flag is the operation id with the CLI's prefix.
        #expect(NetOp.resetDns.flag == "--reset-dns")
        #expect(NetOp.renewDhcp.flag == "--renew-dhcp")
    }
}
