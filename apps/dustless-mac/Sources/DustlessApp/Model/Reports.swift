import Foundation

struct Finding: Codable, Identifiable, Sendable, Hashable {
    let ruleId: String
    let tier: Tier
    let desc: String
    let path: String
    let bytes: UInt64
    let mtime: Double
    let atime: Double
    let ageDays: Double
    let verified: Bool
    let blocked: Bool
    let note: String

    var id: String { path }
}

struct TierTotals: Codable, Sendable {
    let green: TierStat
    let yellow: TierStat
    let red: TierStat
    let blocked: TierStat
}

struct ScanReport: Codable, Sendable {
    let findings: [Finding]
    let totals: TierTotals
    let reclaimable: UInt64
    let freeBefore: UInt64
    let platform: String
    let scannedMs: Int

    var deletable: [Finding] {
        findings.filter(\.isDeletableByEngine)
    }

    var locked: [Finding] {
        findings.filter { !$0.isDeletableByEngine }
    }

    var deletableBytes: UInt64 {
        deletable.reduce(0) { $0 + $1.bytes }
    }
}

enum ApplyStatus: String, Codable, Sendable {
    case deleted
    case skipped
    case failed
}

struct ApplyOutcome: Codable, Sendable, Identifiable {
    let ruleId: String
    let tier: Tier
    let path: String
    let status: ApplyStatus
    let bytes: UInt64
    let detail: String

    var id: String { path }
}

struct ApplyReport: Codable, Sendable {
    let outcomes: [ApplyOutcome]
    let freed: UInt64
    let freeBefore: UInt64
    let freeAfter: UInt64
    let elapsedMs: Int

    var deleted: [ApplyOutcome] { outcomes.filter { $0.status == .deleted } }
    var notDeleted: [ApplyOutcome] { outcomes.filter { $0.status != .deleted } }
}
