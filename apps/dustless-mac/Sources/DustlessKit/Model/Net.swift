import Foundation

public enum NetOutcomeStatus: String, Codable, Sendable {
    case ran
    case refused
    case failed
    case skipped
    case notApplicable = "not-applicable"
}

public struct NetOutcome: Codable, Sendable, Equatable {
    public let op: String
    public let status: NetOutcomeStatus
    public let detail: String
    public let before: String?
    public let after: String?

    public init(op: String, status: NetOutcomeStatus, detail: String, before: String? = nil, after: String? = nil) {
        self.op = op
        self.status = status
        self.detail = detail
        self.before = before
        self.after = after
    }

    public var needsAttention: Bool {
        status == .refused || status == .failed
    }
}

public struct NetReport: Codable, Sendable, Equatable {
    public let platform: String
    public let iface: String?
    public let gateway: String?
    public let dns: [String]
    public let soloRoute: Bool
    public let outcomes: [NetOutcome]

    public init(platform: String, iface: String?, gateway: String?, dns: [String], soloRoute: Bool, outcomes: [NetOutcome]) {
        self.platform = platform
        self.iface = iface
        self.gateway = gateway
        self.dns = dns
        self.soloRoute = soloRoute
        self.outcomes = outcomes
    }

    public func outcome(for id: String) -> NetOutcome? {
        outcomes.first { $0.op == id }
    }
}

public struct NetPrivilege: Codable, Sendable, Equatable {
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

public enum NetOp: String, CaseIterable, Identifiable, Sendable {
    case flushDns = "flush-dns"
    case resetDns = "reset-dns"
    case renewDhcp = "renew-dhcp"
    case clearArp = "clear-arp"
    case resetMtu = "reset-mtu"

    public var id: String { rawValue }

    public var flag: String { "--\(rawValue)" }

    public var labelKey: String {
        switch self {
        case .flushDns: "networkOpFlushDns"
        case .resetDns: "networkOpResetDns"
        case .renewDhcp: "networkOpRenewDhcp"
        case .clearArp: "networkOpClearArp"
        case .resetMtu: "networkOpResetMtu"
        }
    }

    public var helpKey: String { "\(labelKey)Help" }

    public var isAdvanced: Bool { self != .flushDns }

    public var symbol: String {
        switch self {
        case .flushDns: "arrow.clockwise"
        case .resetDns: "globe"
        case .renewDhcp: "arrow.triangle.2.circlepath"
        case .clearArp: "eye.slash"
        case .resetMtu: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        }
    }
}