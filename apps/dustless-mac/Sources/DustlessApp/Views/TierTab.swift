import DustlessKit
import SwiftUI

enum TierTab: String, CaseIterable, Identifiable, Hashable {
    case safe
    case review
    case locked

    var id: String { rawValue }

    /// i18n key for the tab label (`safeTab` / `reviewTab` / `lockedTab`).
    var titleKey: String {
        switch self {
        case .safe: "safeTab"
        case .review: "reviewTab"
        case .locked: "lockedTab"
        }
    }

    /// i18n key for the empty state (`emptySafe` / `emptyReview` / `emptyLocked`).
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

    /// Deliberately no keyboard shortcut. These used to be ⌘1/⌘2/⌘3, and nothing
    /// referenced them — the Go menu owns those keys for the modules, so the tier
    /// switch had two live answers to one keypress.
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
