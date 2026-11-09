import DustlessKit
import SwiftUI

extension Tier {
    var tint: Color {
        switch self {
        case .green: Color(nsColor: .systemGreen)
        case .yellow: Color(nsColor: .systemOrange)
        case .red, .blocked: Color(nsColor: .systemRed)
        }
    }
}

struct TierBadge: View {
    let tier: Tier
    var compact = false

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: tier.symbolName)
                .font(.system(size: compact ? 8 : 9, weight: .semibold))
            Text(settings.tierLabel(tier))
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
        }
        .foregroundStyle(tier.tint)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 3)
        .background(tier.tint.opacity(0.13), in: .capsule)
        .overlay {
            Capsule().stroke(tier.tint.opacity(0.25), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(settings.tierLabel(tier)): \(settings.tierExplanation(tier))")
    }
}
