import DustlessKit
import SwiftUI

enum TierTab: String, CaseIterable, Identifiable, Hashable {
    case safe
    case review
    case locked

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .safe: "safeTab"
        case .review: "reviewTab"
        case .locked: "lockedTab"
        }
    }

    var emptyKey: String {
        switch self {
        case .safe: "emptySafe"
        case .review: "emptyReview"
        case .locked: "emptyLocked"
        }
    }

    var symbolName: String {
        switch self {
        case .safe: Tier.green.symbolName
        case .review: Tier.yellow.symbolName
        case .locked: Tier.blocked.symbolName
        }
    }

    var tint: Color {
        switch self {
        case .safe: .green
        case .review: .orange
        case .locked: .secondary
        }
    }

    func findings(in report: ScanReport) -> [Finding] {
        report.findings.filter { finding in
            switch self {
            case .safe: finding.effectiveTier == .green
            case .review: finding.effectiveTier == .yellow
            case .locked: finding.effectiveTier == .red || finding.effectiveTier == .blocked
            }
        }
    }
}