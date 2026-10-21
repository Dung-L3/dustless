import Testing
import Foundation
import DustlessKit
@Suite("engine payload contract")
struct EngineContractTests {
    @Test func decodesRealScanPayload() throws {
        let report = try JSONDecoder().decode(ScanReport.self, from: fixture("scan.json"))
        #expect(!report.findings.isEmpty)
        #expect(report.reclaimable > 0)
        #expect(report.freeBefore > 0)
        #expect(report.platform == "mac")
        #expect(!report.unscannable.isEmpty)
        #expect(report.unscannableSummary.absent == report.unscannable.filter { $0.reason == .absent }.count)
        #expect(report.unscannableSummary.error == report.unscannable.filter { $0.reason == .error }.count)
        #expect(report.unscannableSummary.noAccess == 0)
        #expect(report.unscannableSummary.notSupported == 0)
        #expect(report.unscannableSummary.red == report.unscannable.filter { $0.reason == .red }.count)
        #expect(report.unscannableSummary.total == report.unscannable.count)
        let avd = try #require(report.unscannable.first { $0.ruleId == "android.avd" })
        #expect(avd.reason == .absent)
        #expect(avd.tier == .yellow)
        #expect(!avd.pathPatterns.isEmpty)
        #expect(report.totals.green.count == 3)
        #expect(report.totals.yellow.count == 3)
        #expect(report.totals.red.count == 0)
        #expect(report.totals.blocked.count == 1)
        #expect(report.totals.green.bytes == 522_240)
        #expect(report.totals.yellow.bytes == 3_174_401)
    }

    @Test func rejectsAnUnknownUnscannableReasonRatherThanGuessing() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(UnscannableRule.self, from: Data(#"""
            {"ruleId":"r","tier":"green","desc":"d","reason":"maybe","pathPatterns":["/a"]}
            """#.utf8))
        }
    }

    @Test func decodesRealApplyPayload() throws {
        let report = try JSONDecoder().decode(ApplyReport.self, from: fixture("apply.json"))
        #expect(report.freeBefore >= 0)
        #expect(report.freeAfter >= 0)
        #expect(report.elapsedMs >= 0)
    }

    @Test func theApplyPayloadSeparatesDeletedBytesFromTheVolumeDelta() throws {
        let report = try JSONDecoder().decode(ApplyReport.self, from: fixture("apply.json"))
        let deletedBytes = report.outcomes.filter { $0.status == .deleted }.reduce(UInt64(0)) { $0 + $1.bytes }
        #expect(report.deletedBytes == deletedBytes)
        #expect(report.freed == report.volumeDelta)
        #expect(report.outcomes.filter { $0.status != .deleted }.allSatisfy { $0.bytes == 0 })
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
        #expect(!report.deletable.isEmpty)
        #expect(report.initialSelection.isEmpty)
    }
}
