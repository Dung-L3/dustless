import Foundation

public struct Finding: Codable, Identifiable, Sendable, Hashable {
    public let ruleId: String
    public let tier: Tier
    public let desc: String
    public let path: String
    public let bytes: UInt64
    public let mtime: Double
    public let atime: Double
    public let ageDays: Double
    public let verified: Bool
    public let blocked: Bool
    public let note: String

    public var id: String { path }
}

public struct TierTotals: Codable, Sendable {
    public let green: TierStat
    public let yellow: TierStat
    public let red: TierStat
    public let blocked: TierStat
}

public struct ScanReport: Codable, Sendable {
    public let findings: [Finding]
    public let totals: TierTotals
    public let reclaimable: UInt64
    public let freeBefore: UInt64
    public let platform: String
    public let scannedMs: Int

    public var deletable: [Finding] {
        findings.filter(\.isDeletableByEngine)
    }

    public var locked: [Finding] {
        findings.filter { !$0.isDeletableByEngine }
    }

    /// Safety invariant: a scan never pre-selects anything. The engine fails
    /// closed (`src/core/apply.ts`) and the UI must too — the user opts in to
    /// each path, so a fresh report starts with an empty selection.
    public var initialSelection: Set<String> { [] }
}

public enum ApplyStatus: String, Codable, Sendable {
    case deleted
    case skipped
    case failed
}

public struct ApplyOutcome: Codable, Sendable, Identifiable {
    public let ruleId: String
    public let tier: Tier
    public let path: String
    public let status: ApplyStatus
    public let bytes: UInt64
    public let detail: String

    public var id: String { path }
}

public struct ApplyReport: Codable, Sendable {
    public let outcomes: [ApplyOutcome]
    public let freed: UInt64
    public let freeBefore: UInt64
    public let freeAfter: UInt64
    public let elapsedMs: Int

    public var deleted: [ApplyOutcome] { outcomes.filter { $0.status == .deleted } }
}
