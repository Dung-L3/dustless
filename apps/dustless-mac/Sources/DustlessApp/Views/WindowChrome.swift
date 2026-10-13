import DustlessKit
import SwiftUI
import AppKit

/// One visual language for the app's secondary windows. The Memory and Storage
/// panels used to spell their own headers, cards and row helpers, so the two
/// drifted apart; everything shared now lives here.

// MARK: - Cards

/// Metrics used by every tile, volume card and metric grid in both windows.
enum PanelStyle {
    static let cardFill = Color.secondary.opacity(0.18)
    static let rowFill = Color.secondary.opacity(0.10)
    static let radius: CGFloat = 8
}

extension View {
    /// The standard tile background: one corner radius, one fill, everywhere.
    func panelCard(_ fill: Color = PanelStyle.cardFill) -> some View {
        background(fill, in: .rect(cornerRadius: PanelStyle.radius))
    }

    /// Section label above a group of rows or cards.
    func panelSectionHeader() -> some View {
        font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

/// A labelled number. The Memory metric grid and the volume cards both render
/// their numbers through this, so a byte value looks the same in either window.
struct MetricCard: View {
    let label: String
    let value: String
    /// Volume cards pack three tiles side by side, so they get the smaller scale.
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: compact ? 12 : 13, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - Chips

/// A coloured dot with a short label in a tinted capsule. Carries the memory
/// pressure state and each process category, so both read the same way.
struct StatusChip: View {
    let color: Color
    let text: String
    /// Tinted chips read as status; muted ones read as metadata.
    var prominent: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(prominent ? Color.primary : Color.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(prominent ? 0.16 : 0.12), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Header

/// The title row every panel shares: a title, an optional secondary line, then
/// the panel's controls ending with the close button.
struct PanelHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            accessory
            CloseWindowButton()
        }
    }
}

struct CloseWindowButton: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.closeWindow) private var closeWindow

    var body: some View {
        Button(action: { closeWindow() }) {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help(settings.t("close"))
        .accessibilityLabel(settings.t("close"))
    }
}

/// A compact bordered refresh button, used by the panels that re-read on demand.
struct RefreshButton: View {
    let isBusy: Bool
    let action: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(settings.t("refresh"))
            }
        }
        .controlSize(.small)
        .disabled(isBusy)
        .help(settings.t("refreshHelp"))
        .accessibilityLabel(settings.t("refresh"))
    }
}

// MARK: - Path actions

/// Shared context menu for file path actions (Reveal in Finder, Copy Path).
struct PathContextMenu: ViewModifier {
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

extension View {
    func pathContextMenu(_ path: String) -> some View {
        modifier(PathContextMenu(path: path))
    }
}