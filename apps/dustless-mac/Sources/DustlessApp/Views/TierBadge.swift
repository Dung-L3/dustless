import DustlessKit
import SwiftUI

struct TierBadge: View {
    let tier: Tier
    var compact = false

    @EnvironmentObject private var settings: AppSettings

    private var tint: Color {
        switch tier {
        case .green: .green
        case .yellow: .orange
        case .red: .red
        case .blocked: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tier.symbolName)
                .font(.system(size: compact ? 9 : 10, weight: .bold))
            Text(settings.tierLabel(tier))
                .font(.system(size: compact ? 9 : 10, weight: .heavy))
                .tracking(0.7)
                .textCase(.uppercase)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2.5 : 3.5)
        .background(tint.opacity(0.14), in: .rect(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(tint.opacity(0.28), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(settings.tierLabel(tier)): \(settings.tierExplanation(tier))")
    }
}
