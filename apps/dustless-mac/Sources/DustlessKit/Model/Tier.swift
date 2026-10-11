import Foundation

public enum Tier: String, Codable, CaseIterable, Sendable {
    case green
    case yellow
    case red
    case blocked

    public var label: String {
        switch self {
        case .green: "SAFE"
        case .yellow: "REVIEW"
        case .red: "PROTECTED"
        case .blocked: "LOCKED"
        }
    }

    public var symbolName: String {
        switch self {
        case .green: "checkmark.seal.fill"
        case .yellow: "exclamationmark.triangle.fill"
        case .red: "hand.raised.fill"
        case .blocked: "lock.fill"
        }
    }

    public var explanation: String {
        switch self {
        case .green: "Regenerable cache. Safe to remove."
        case .yellow: "May still be in use. Review before removing."
        case .red: "Real user data. The engine refuses to delete it."
        case .blocked: "Cross-verification failed. The engine refuses to delete it."
        }
    }
}

public struct TierStat: Codable, Sendable {
    public let count: Int
    public let bytes: UInt64
}

public extension Finding {
    public var effectiveTier: Tier {
        blocked ? .blocked : tier
    }

    public var isDeletableByEngine: Bool {
        !blocked && tier != .red
    }
}
