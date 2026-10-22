import DustlessKit
import SwiftUI

struct FindingRow: View {
    let finding: Finding
    let isSelected: Bool
    let onToggle: () -> Void

    @EnvironmentObject private var settings: AppSettings

    private var deletable: Bool { finding.isDeletableByEngine }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if deletable {
                Button(action: onToggle) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help(settings.t(isSelected ? "includeInCleanup" : "excludeFromCleanup"))
                .accessibilityLabel(settings.t(isSelected ? "includedLabel" : "excludedLabel"))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("cleanup.toggle.\(finding.path)")
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 15, height: 18)
                    .help(settings.t("lockedTooltip"))
                    .accessibilityLabel(settings.t("lockedNeverDeleted"))
                    .accessibilityIdentifier("cleanup.locked.\(finding.path)")
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    TierBadge(tier: finding.effectiveTier, compact: true)
                    Text(finding.ruleId)
                        .font(PanelFont.emphasis(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(ByteFormat.string(finding.bytes))
                        .font(PanelFont.number(.semibold))
                        .foregroundStyle(deletable ? .primary : .secondary)
                        .frame(width: PanelStyle.byteColumnWidth, alignment: .trailing)
                    Text(settings.age(finding.ageDays))
                        .font(PanelFont.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 58, alignment: .trailing)
                }

                Text(finding.path)
                    .font(PanelFont.mono(11))
                    .foregroundStyle(deletable ? .secondary : .tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .accessibilityLabel(settings.t("pathA11y", ["path": finding.path]))

                Text(RuleText.description(of: finding, lang: settings.language))
                    .font(PanelFont.secondary)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(nil)

                if let reasonText {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 9))
                        Text(reasonText)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(nil)
                    }
                    .font(PanelFont.caption)
                    .foregroundStyle(finding.effectiveTier == .blocked ? Color.red : Color.secondary)
                }
            }
        }
        .padding(.vertical, PanelStyle.Space.s)
        .padding(.horizontal, PanelStyle.Space.m)
        .frame(minHeight: PanelStyle.rowMinHeight)
        .background(rowBackground)
        .contentShape(.rect)
        .pathContextMenu(finding.path)
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

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: PanelStyle.radius)
            .fill(isSelected && deletable ? Color.accentColor.opacity(0.07) : Color.clear)
            .overlay(alignment: .leading) {
                if deletable {
                    Capsule()
                        .fill(isSelected ? Color.accentColor : Color.clear)
                        .frame(width: 2.5)
                } else {
                    Capsule()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 2.5)
                }
            }
    }
}
