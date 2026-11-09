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
        case .safe: Theme.Palette.accent
        case .review: Theme.Palette.warning
        case .locked: Theme.Palette.danger
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
struct TierPillBar: View {
    @ObservedObject var store: ScanStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(TierTab.allCases) { tab in
                let count = store.report.map { tab.findings(in: $0).count } ?? 0
                let active = store.tierTab == tab
                Button {
                    withAnimation(Motion.gated(reduceMotion, Motion.control)) {
                        store.tierTab = tab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.symbolName)
                            .font(.system(size: 10, weight: .semibold))
                        Text(settings.tabTitle(tab))
                            .font(Theme.Font.label)
                        Text("\(count)")
                            .font(Theme.Font.caption)
                            .foregroundStyle(active ? Theme.Palette.textPrimary : Theme.Palette.textMuted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.Palette.ink.opacity(0.16), in: .capsule)
                    }
                    .foregroundStyle(active ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(active ? Theme.Palette.selection : Color.clear, in: .capsule)
                    .overlay {
                        Capsule().stroke(active ? tab.tint.opacity(0.45) : Theme.Palette.hairline, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(settings.tabTitle(tab)): \(settings.itemCount(count))")
                .accessibilityAddTraits(active ? [.isSelected] : [])
                .accessibilityIdentifier("cleanup.tier.\(tab.rawValue)")
            }
            Spacer(minLength: 0)
        }
    }
}
