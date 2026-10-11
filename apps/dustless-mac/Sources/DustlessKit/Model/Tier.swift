import Foundation

public enum Tier: String, Codable, CaseIterable, Sendable {
    case green
    case yellow
    case red
    case blocked

    public var symbolName: String {
        switch self {
        case .green: "checkmark.seal.fill"
        case .yellow: "exclamationmark.triangle.fill"
        case .red: "hand.raised.fill"
        case .blocked: "lock.fill"
        }
    }
}

public struct TierStat: Codable, Sendable {
    public let count: Int
    public let bytes: UInt64
}

public extension Finding {
    var effectiveTier: Tier {
        blocked ? .blocked : tier
    }

    var isDeletableByEngine: Bool {
        !blocked && tier != .red
    }
}
