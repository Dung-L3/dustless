import Foundation

enum Tier: String, Codable, CaseIterable, Sendable {
    case green
    case yellow
    case red
    case blocked

    var label: String {
        switch self {
        case .green: "SAFE"
        case .yellow: "REVIEW"
        case .red: "PROTECTED"
        case .blocked: "LOCKED"
        }
    }

    var symbolName: String {
        switch self {
        case .green: "checkmark.seal.fill"
        case .yellow: "exclamationmark.triangle.fill"
        case .red: "hand.raised.fill"
        case .blocked: "lock.fill"
        }
    }

    var explanation: String {
        switch self {
        case .green: "Regenerable cache. Safe to remove."
        case .yellow: "May still be in use. Review before removing."
        case .red: "Real user data. The engine refuses to delete it."
        case .blocked: "Cross-verification failed. The engine refuses to delete it."
        }
    }
}

struct TierStat: Codable, Sendable {
    let count: Int
    let bytes: UInt64
}

extension Finding {
    var effectiveTier: Tier {
        blocked ? .blocked : tier
    }

    var isDeletableByEngine: Bool {
        !blocked && tier != .red
    }
}
