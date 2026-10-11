import DustlessKit
import SwiftUI

enum TierTab: String, CaseIterable, Identifiable, Hashable {
    case safe
    case review
    case locked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        case .locked: "Locked"
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

    var shortcut: KeyboardShortcut {
        switch self {
        case .safe: KeyboardShortcut("1", modifiers: .command)
        case .review: KeyboardShortcut("2", modifiers: .command)
        case .locked: KeyboardShortcut("3", modifiers: .command)
        }
    }

    var emptyTitle: String { "No \(title.lowercased()) findings" }

    var emptyMessage: String {
        switch self {
        case .safe: "Regenerable caches that are safe to remove would appear here."
        case .review: "Items that may still be in use would appear here."
        case .locked: "Items the engine refuses to delete would appear here."
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
