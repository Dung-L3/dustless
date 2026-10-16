import Foundation

/// The live state of the AWDL (AirDrop) radio. Mirrors `AwdlState` in
/// `src/core/net/awdl.ts`; the raw values are the wire format, not a paraphrase.
public enum AwdlState: String, Codable, Sendable {
    case on
    case off
    case absent
}

public enum AwdlOutcomeStatus: String, Codable, Sendable {
    case ran
    case refused
    case failed
    case notApplicable = "not-applicable"
}

public struct AwdlOutcome: Codable, Sendable, Equatable {
    public let status: AwdlOutcomeStatus
    public let detail: String

    public init(status: AwdlOutcomeStatus, detail: String) {
        self.status = status
        self.detail = detail
    }
}

/// The report from `dustless awdl --json`. `outcome` is null for a read-only
/// status call and set once a toggle has been attempted.
public struct AwdlReport: Codable, Sendable, Equatable {
    public let platform: String
    public let interface: String?
    public let state: AwdlState
    public let changed: Bool
    public let outcome: AwdlOutcome?

    public init(platform: String, interface: String?, state: AwdlState, changed: Bool, outcome: AwdlOutcome?) {
        self.platform = platform
        self.interface = interface
        self.state = state
        self.changed = changed
        self.outcome = outcome
    }
}

/// The single sudoers rule the app installs for one-click toggling. Printed by
/// `dustless awdl --print-privilege`, so the app never keeps its own copy of the
/// rule text.
public struct AwdlPrivilege: Codable, Sendable, Equatable {
    public let user: String
    public let path: String
    public let allowed: [String]
    public let rule: String

    public init(user: String, path: String, allowed: [String], rule: String) {
        self.user = user
        self.path = path
        self.allowed = allowed
        self.rule = rule
    }
}
