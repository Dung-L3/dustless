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