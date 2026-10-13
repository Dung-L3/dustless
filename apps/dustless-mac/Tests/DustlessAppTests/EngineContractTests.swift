import Testing
import Foundation
import DustlessKit

private let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
private let fixtures = here.appendingPathComponent("Fixtures")

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

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtures.appendingPathComponent(name))
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