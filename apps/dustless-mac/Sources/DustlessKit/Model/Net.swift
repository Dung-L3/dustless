import Foundation

/// The outcome of one network operation. These raw values are the wire format
/// in `NetOutcome` (`src/core/net/index.ts`), not a paraphrase: an unknown
/// status fails the decode instead of being guessed at.
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
    /// The engine's own sentence about what happened — in the engine's language,
    /// which is why the UI shows it verbatim instead of paraphrasing it.
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

    /// A refusal is not a failure, and neither is a skip — only a real error is
    /// worth tinting red.
    public var needsAttention: Bool {
        status == .refused || status == .failed
    }
}

/// The report from `dustless net --json`. `iface`/`gateway` are null when the
/// engine found no active route, and `outcomes` is empty for a read-only call
/// made with `--advanced` and no named operation.
public struct NetReport: Codable, Sendable, Equatable {
    public let platform: String
    public let iface: String?
    public let gateway: String?
    public let dns: [String]
    /// True when this interface is the machine's only way to the network. The
    /// engine refuses the interface-touching operations in that case unless the
    /// caller passes `--force`.
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

    /// The answer for one operation, from whichever report is on screen.
    public func outcome(for id: String) -> NetOutcome? {
        outcomes.first { $0.op == id }
    }
}

/// The operations the app offers, mirroring `OPS` in
/// `src/core/net/commands.ts`.
///
/// `flush-routing` is deliberately absent: on macOS the engine refuses it by
/// design (`route flush` would drop the default route), so there is nothing
/// here a click could do. It stays on the CLI for the Linux side.
public enum NetOp: String, CaseIterable, Identifiable, Sendable {
    case flushDns = "flush-dns"
    case resetDns = "reset-dns"
    case renewDhcp = "renew-dhcp"
    case clearArp = "clear-arp"
    case resetMtu = "reset-mtu"

    /// The wire operation id, which is also what `NetOutcome.op` reports back.
    public var id: String { rawValue }

    /// The engine flag that runs exactly this operation, e.g. `--renew-dhcp`.
    /// Advanced operations run one at a time, which is how the CLI is designed.
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

    /// One line saying what the operation does, in the user's language.
    public var helpKey: String { "\(labelKey)Help" }

    /// Advanced operations change live network state and the engine refuses them
    /// without root, so the app escalates through one admin prompt per run.
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