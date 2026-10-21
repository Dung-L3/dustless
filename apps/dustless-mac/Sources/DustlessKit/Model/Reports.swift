import Foundation

public struct Reason: Codable, Sendable, Hashable {
    public let code: String
    public let params: [String: String]?

    public init(code: String, params: [String: String]? = nil) {
        self.code = code
        self.params = params
    }
}

public enum ReasonText {
    public static func text(_ reason: Reason?, lang: Lang) -> String {
        guard let reason else { return "" }
        let cause = reason.params?["cause"].map { L10n.render(lang, "reason.cause.\($0)", reason.params ?? [:]) }
        var vars = reason.params ?? [:]
        if let cause { vars["cause"] = cause }
        return L10n.render(lang, "reason.\(reason.code)", vars)
    }

    public static func text(_ reasons: [Reason], lang: Lang) -> String {
        reasons.map { text($0, lang: lang) }.joined(separator: " · ")
    }
}

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
    public let note: [Reason]

    public var id: String { path }
}

public struct TierTotals: Codable, Sendable {
    public let green: TierStat
    public let yellow: TierStat
    public let red: TierStat
    public let blocked: TierStat
}

public enum UnscannableReason: String, Codable, CaseIterable, Sendable {
    case absent
    case noAccess = "no_access"
    case notSupported = "not_supported"
    case error
    case red
    case protected = "protected"
}

public struct UnscannableRule: Codable, Sendable, Hashable {
    public let ruleId: String
    public let tier: Tier
    public let desc: String
    public let reason: UnscannableReason
    public let pathPatterns: [String]
}

public struct UnscannableSummary: Codable, Sendable, Hashable {
    public let absent: Int
    public let noAccess: Int
    public let notSupported: Int
    public let error: Int
    public let red: Int
    public let protected: Int

    private enum CodingKeys: String, CodingKey {
        case absent
        case noAccess = "no_access"
        case notSupported = "not_supported"
        case error
        case red
        case protected
    }

    public init(absent: Int, noAccess: Int, notSupported: Int, error: Int, red: Int = 0, protected: Int = 0) {
        self.absent = absent
        self.noAccess = noAccess
        self.notSupported = notSupported
        self.error = error
        self.red = red
        self.protected = protected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        absent = try container.decode(Int.self, forKey: .absent)
        noAccess = try container.decode(Int.self, forKey: .noAccess)
        notSupported = try container.decode(Int.self, forKey: .notSupported)
        error = try container.decode(Int.self, forKey: .error)
        red = try container.decodeIfPresent(Int.self, forKey: .red) ?? 0
        protected = try container.decodeIfPresent(Int.self, forKey: .protected) ?? 0
    }

    public var total: Int {
        absent + noAccess + notSupported + error + red + protected
    }
}

public struct ScanReport: Codable, Sendable {
    public let schemaVersion: Int
    public let findings: [Finding]
    public let totals: TierTotals
    public let reclaimable: UInt64
    public let freeBefore: UInt64
    public let platform: String
    public let scannedMs: Int
    public let unscannable: [UnscannableRule]
    public let unscannableSummary: UnscannableSummary

    public init(schemaVersion: Int = EngineContract.currentSchemaVersion, findings: [Finding], totals: TierTotals, reclaimable: UInt64, freeBefore: UInt64, platform: String, scannedMs: Int, unscannable: [UnscannableRule], unscannableSummary: UnscannableSummary) {
        self.schemaVersion = schemaVersion
        self.findings = findings
        self.totals = totals
        self.reclaimable = reclaimable
        self.freeBefore = freeBefore
        self.platform = platform
        self.scannedMs = scannedMs
        self.unscannable = unscannable
        self.unscannableSummary = unscannableSummary
    }

    public var deletable: [Finding] {
        findings.filter(\.isDeletableByEngine)
    }

    public var locked: [Finding] {
        findings.filter { !$0.isDeletableByEngine }
    }

    public var initialSelection: Set<String> { [] }
}

public enum UnscannableText {
    public static func reasonsPresent(in summary: UnscannableSummary) -> [UnscannableReason] {
        var result: [UnscannableReason] = []
        if summary.absent > 0 { result.append(.absent) }
        if summary.noAccess > 0 { result.append(.noAccess) }
        if summary.notSupported > 0 { result.append(.notSupported) }
        if summary.error > 0 { result.append(.error) }
        if summary.red > 0 { result.append(.red) }
        if summary.protected > 0 { result.append(.protected) }
        return result
    }

    public static func reasonLabel(_ reason: UnscannableReason, lang: Lang) -> String {
        let key = "scan.unscannable.reason.\(reason.rawValue)"
        return L10n.render(lang, key)
    }

    public static func bannerParts(report: ScanReport, lang: Lang) -> (count: Int, reasonLabels: [String])? {
        guard report.unscannableSummary.total > 0 else { return nil }
        let reasons = reasonsPresent(in: report.unscannableSummary)
        let labels = reasons.map { reasonLabel($0, lang: lang) }
        return (report.unscannableSummary.total, labels)
    }
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
    public let detail: Reason?

    public var id: String { path }
}

public struct ApplyReport: Codable, Sendable {
    public let schemaVersion: Int
    public let outcomes: [ApplyOutcome]
    public let deletedBytes: UInt64
    public let freed: UInt64
    public let freeBefore: UInt64
    public let freeAfter: UInt64
    public let elapsedMs: Int

    public var deleted: [ApplyOutcome] { outcomes.filter { $0.status == .deleted } }

    public var volumeDelta: UInt64 { freeAfter >= freeBefore ? freeAfter - freeBefore : 0 }
}
