import Testing
import Foundation
import DustlessKit

@Suite("quick clean scope")
struct QuickCleanScopeTests {
    private func finding(tier: String, blocked: Bool, path: String = "/tmp/x", bytes: UInt64 = 10) throws -> Finding {
        try JSONDecoder().decode(Finding.self, from: Data("""
        {"ruleId":"r","tier":"\(tier)","desc":"d","path":"\(path)","bytes":\(bytes),
         "mtime":0,"atime":0,"ageDays":10,"verified":\(!blocked),"blocked":\(blocked),"note":[]}
        """.utf8))
    }

    private func report(_ findings: [Finding], free: UInt64 = 0) throws -> ScanReport {
        let totals = try JSONDecoder().decode(
            TierTotals.self,
            from: Data(#"{"green":{"count":0,"bytes":0},"yellow":{"count":0,"bytes":0},"red":{"count":0,"bytes":0},"blocked":{"count":0,"bytes":0}}"#.utf8)
        )
        return ScanReport(
            findings: findings,
            totals: totals,
            reclaimable: 0,
            freeBefore: free,
            platform: "darwin",
            scannedMs: 1,
            unscannable: [],
            unscannableSummary: UnscannableSummary(absent: 0, noAccess: 0, notSupported: 0, error: 0)
        )
    }

    @Test func onlyUnblockedGreenFindingsAreInScope() throws {
        let scoped = try report([
            try finding(tier: "green", blocked: false, path: "/tmp/green", bytes: 100),
            try finding(tier: "yellow", blocked: false, path: "/tmp/yellow"),
            try finding(tier: "green", blocked: true, path: "/tmp/blocked-green"),
            try finding(tier: "red", blocked: false, path: "/tmp/red"),
            try finding(tier: "blocked", blocked: true, path: "/tmp/blocked"),
        ]).quickCleanFindings()
        #expect(scoped.map(\.path) == ["/tmp/green"])
        #expect(scoped.map(\.bytes) == [100])
    }

    @Test func emptyScopeWhenNoGreenFindings() throws {
        let scoped = try report([
            try finding(tier: "yellow", blocked: false, path: "/tmp/yellow"),
            try finding(tier: "red", blocked: false, path: "/tmp/red"),
        ]).quickCleanFindings()
        #expect(scoped.isEmpty)
        #expect(try report([]).quickCleanFindings().isEmpty)
    }
}
