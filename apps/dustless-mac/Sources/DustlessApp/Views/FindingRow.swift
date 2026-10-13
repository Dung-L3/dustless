import DustlessKit
import SwiftUI
import AppKit

/// Shared context menu for file path actions (Reveal in Finder, Copy Path).
private struct PathContextMenu: ViewModifier {
    let path: String
    @EnvironmentObject private var settings: AppSettings

    func body(content: Content) -> some View {
        content.contextMenu {
            Button(settings.t("revealInFinder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            Button(settings.t("copyPath")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
    }
}

private extension View {
    func pathContextMenu(_ path: String) -> some View {
        modifier(PathContextMenu(path: path))
    }
}

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
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 15, height: 18)
                    .help(settings.t("lockedTooltip"))
                    .accessibilityLabel(settings.t("lockedNeverDeleted"))
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    TierBadge(tier: finding.effectiveTier, compact: true)
                    Text(finding.ruleId)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(ByteFormat.string(finding.bytes))
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(deletable ? .primary : .secondary)
                    Text(settings.age(finding.ageDays))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(width: 58, alignment: .trailing)
                }

                Text(finding.path)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(deletable ? .secondary : .tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .accessibilityLabel(settings.t("pathA11y", ["path": finding.path]))

                Text(finding.desc)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(nil)

                if !finding.note.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 9))
                        Text(finding.note)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(nil)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(finding.effectiveTier == .blocked ? Color.red : Color.secondary)
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(rowBackground)
        .contentShape(.rect)
        .pathContextMenu(finding.path)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8)
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
