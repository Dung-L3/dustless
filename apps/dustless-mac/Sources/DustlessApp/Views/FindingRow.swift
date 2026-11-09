import DustlessKit
import SwiftUI

struct FindingRow: View {
    let finding: Finding
    let isSelected: Bool
    let onToggle: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @State private var hovered = false

    private var deletable: Bool { finding.isDeletableByEngine }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            control
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.Space.s) {
                    TierBadge(tier: finding.effectiveTier, compact: true)
                    Text(RuleText.description(of: finding, lang: settings.language))
                        .font(Theme.Font.label)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Theme.Space.s)
                    Text(ByteFormat.string(finding.bytes))
                        .font(Theme.Font.number(.semibold, size: 13))
                        .foregroundStyle(deletable ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                        .frame(width: Theme.Size.byteColumn, alignment: .trailing)
                    Text(settings.age(finding.ageDays))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textMuted)
                        .frame(width: 56, alignment: .trailing)
                }

                HStack(spacing: 6) {
                    Text(finding.ruleId)
                        .font(Theme.Font.mono)
                        .foregroundStyle(Theme.Palette.textMuted)
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(Theme.Palette.textMuted)
                    PathText(path: finding.path, font: Theme.Font.caption)
                }

                if let reasonText {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 9))
                        Text(reasonText)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(2)
                    }
                    .font(Theme.Font.caption)
                    .foregroundStyle(finding.effectiveTier == .blocked ? Color(nsColor: .systemRed) : Theme.Palette.textSecondary)
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, Theme.Space.m)
        .frame(minHeight: Theme.Size.row)
        .background(
            isSelected && deletable ? Theme.Palette.selection : (hovered ? Theme.Palette.hover : Color.clear),
            in: .rect(cornerRadius: Theme.Radius.row)
        )
        .overlay(alignment: .leading) {
            Capsule()
                .fill(finding.effectiveTier.tint)
                .frame(width: isSelected && deletable ? 2.5 : 0)
                .padding(.vertical, 10)
        }
        .contentShape(.rect)
        .onHover { hovered = $0 }
        .pathContextMenu(finding.path)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var control: some View {
        if deletable {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.Palette.accent : Theme.Palette.textMuted)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(settings.t(isSelected ? "includeInCleanup" : "excludeFromCleanup"))
            .accessibilityLabel(settings.t(isSelected ? "includedLabel" : "excludedLabel"))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("cleanup.toggle.\(finding.path)")
        } else {
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.textMuted)
                .frame(width: 22, height: 22)
                .help(settings.t("lockedTooltip"))
                .accessibilityLabel(settings.t("lockedNeverDeleted"))
                .accessibilityIdentifier("cleanup.locked.\(finding.path)")
        }
    }

    private var reasonText: String? {
        if !finding.note.isEmpty {
            return ReasonText.text(finding.note, lang: settings.language)
        }
        if !deletable {
            return settings.tierExplanation(finding.effectiveTier)
        }
        return nil
    }
}
