import AppKit
import DustlessKit
import SwiftUI

struct ApplicationUninstallSheet: View {
    let app: InstalledApp
    let isRunning: Bool
    let isWorking: Bool
    let isQuitting: Bool
    let onConfirm: (Bool, Bool) -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @State private var includeRelated = false
    @State private var permanent = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            header
            metrics
            if isRunning { runningWarning }
            relatedToggle
            affected
            footer
        }
        .padding(Theme.Space.xl)
        .frame(width: 620)
        .background(Theme.Palette.surface)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(nsImage: ApplicationsIconCache.icon(for: app.path))
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(permanent ? settings.t("appsPurgeTitle") : settings.t("appsRemoveTitle"))
                    .font(Theme.Font.title)
                Text(app.name)
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(app.bundleId)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textMuted)
            }
            Spacer()
        }
    }

    private var metrics: some View {
        HStack(spacing: Theme.Space.m) {
            MetricTile(label: settings.t("appBundle"), value: ByteFormat.string(app.bytes))
            MetricTile(
                label: settings.t("relatedData"),
                value: app.relatedBytes.map(ByteFormat.string) ?? "—",
                detail: settings.relatedCount(app.relatedItems.count)
            )
            MetricTile(
                label: settings.t("totalLabel"),
                value: totalValue,
                detail: nil
            )
        }
    }

    private var totalValue: String {
        guard includeRelated else { return ByteFormat.string(app.bytes) }
        guard let related = app.relatedBytes else { return "—" }
        return ByteFormat.string(app.bytes + related)
    }

    private var runningWarning: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Palette.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.t("appRunning"))
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(settings.t("appsQuitFirst"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.Palette.warningFill, in: .rect(cornerRadius: Theme.Radius.inner))
    }

    private var relatedToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                includeRelated.toggle()
            } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: includeRelated ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(includeRelated ? Theme.Palette.accent : Theme.Palette.textMuted)
                    Text(settings.t("appsIncludeRelated"))
                        .font(Theme.Font.label)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
            .accessibilityLabel(settings.t("appsIncludeRelated"))
            .accessibilityAddTraits(includeRelated ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("applications.includeRelated")
            Text(settings.t(includeRelated ? "appsKeepPersonal" : "appsRelatedKept"))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textMuted)
        }
    }

    private var affected: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(settings.t("affectedLocations"))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    affectedRow(path: app.path, label: settings.t("appBundle"), bytes: app.bytes)
                    if includeRelated {
                        ForEach(app.relatedItems) { item in
                            affectedRow(
                                path: item.path,
                                label: settings.t(relatedLabel(item)),
                                bytes: item.bytes
                            )
                        }
                    }
                }
            }
            .frame(maxHeight: 150)
        }
    }

    private func affectedRow(path: String, label: String, bytes: UInt64?) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 108, alignment: .leading)
            PathText(path: path, font: Theme.Font.caption)
            Spacer(minLength: Theme.Space.s)
            Text(bytes.map(ByteFormat.string) ?? "—")
                .font(Theme.Font.number(size: 11))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private var footer: some View {
        VStack(alignment: .trailing, spacing: Theme.Space.s) {
            HStack {
                Button(settings.t("confirmCancel"), action: onCancel)
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                    .accessibilityIdentifier("applications.cancel")
                Spacer()
                if isWorking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(isQuitting ? settings.t("appsQuitFirst") : settings.t("busyDeleting", ["n": "\(1 + (includeRelated ? app.relatedItems.count : 0))"]))
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                Button {
                    onConfirm(includeRelated, permanent)
                } label: {
                    Text(permanent ? settings.t("appsPurgeAction") : settings.t("appsMoveToTrash"))
                }
                .buttonStyle(DestructiveButtonStyle())
                .disabled(isWorking)
                .accessibilityIdentifier("applications.confirm")
            }
            Button {
                permanent.toggle()
            } label: {
                Text(settings.t(permanent ? "appsKeepReversible" : "appsMakePermanent"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textMuted)
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
            .accessibilityIdentifier("applications.permanentToggle")
        }
    }

    private func relatedLabel(_ item: RelatedItem) -> String {
        switch item.kind {
        case "app-support": "relatedSupport"
        case "caches", "webkit", "http-storage": "relatedCache"
        case "preferences", "cookies": "relatedPreferences"
        case "logs": "relatedLogs"
        case "saved-state": "relatedSavedState"
        case "container", "group-container": "relatedContainer"
        default: "relatedOther"
        }
    }
}
