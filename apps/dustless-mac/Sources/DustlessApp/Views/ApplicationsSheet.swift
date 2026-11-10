import AppKit
import DustlessKit
import SwiftUI

enum ApplicationUninstallMode: String, CaseIterable, Identifiable {
    case applicationOnly
    case applicationAndData

    var id: String { rawValue }
}

struct ApplicationUninstallSheet: View {
    let app: InstalledApp
    let isRunning: Bool
    let isWorking: Bool
    let isQuitting: Bool
    let onConfirm: ([String], Bool) -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @State private var mode: ApplicationUninstallMode = .applicationOnly
    @State private var selectedPaths: Set<String>
    @State private var permanent = false

    init(
        app: InstalledApp,
        isRunning: Bool,
        isWorking: Bool,
        isQuitting: Bool,
        onConfirm: @escaping ([String], Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.app = app
        self.isRunning = isRunning
        self.isWorking = isWorking
        self.isQuitting = isQuitting
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _selectedPaths = State(initialValue: Set(app.relatedItems.map(\.path)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            header
            metrics
            if isRunning { runningWarning }
            modeSelector
            if mode == .applicationAndData { relatedSelection } else { keptNote }
            affected
            footer
        }
        .padding(Theme.Space.xl)
        .frame(width: 640)
        .background(Theme.Palette.surface)
    }

    private var title: String {
        switch (mode, permanent) {
        case (.applicationOnly, false): settings.t("appsRemoveApplicationTitle")
        case (.applicationOnly, true): settings.t("appsDeleteApplicationTitle")
        case (.applicationAndData, false): settings.t("appsRemoveAppAndDataTitle")
        case (.applicationAndData, true): settings.t("appsDeleteAppAndDataTitle")
        }
    }

    private var confirmTitle: String {
        switch (mode, permanent) {
        case (.applicationOnly, false): settings.t("appsRemoveApplicationAction")
        case (.applicationOnly, true): settings.t("appsDeleteApplicationAction")
        case (.applicationAndData, false): settings.t("appsRemoveAppAndDataAction")
        case (.applicationAndData, true): settings.t("appsDeleteAppAndDataAction")
        }
    }

    private var selectedRelated: [RelatedItem] {
        app.relatedItems.filter { selectedPaths.contains($0.path) }
    }

    private var selectedRelatedBytes: UInt64? {
        guard !selectedRelated.isEmpty else { return 0 }
        let values = selectedRelated.compactMap(\.bytes)
        guard values.count == selectedRelated.count else { return nil }
        return values.reduce(0, +)
    }

    private var totalBytes: UInt64? {
        guard mode == .applicationAndData else { return app.bytes }
        guard let related = selectedRelatedBytes else { return nil }
        return app.bytes + related
    }

    private var selectionIsValid: Bool {
        mode == .applicationOnly || !selectedRelated.isEmpty
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(nsImage: ApplicationsIconCache.icon(for: app.path))
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
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
                value: mode == .applicationAndData
                    ? (selectedRelatedBytes.map(ByteFormat.string) ?? "—")
                    : settings.t("appsKept"),
                detail: mode == .applicationAndData
                    ? settings.relatedCount(selectedRelated.count)
                    : settings.relatedCount(app.relatedItems.count)
            )
            MetricTile(
                label: settings.t("totalLabel"),
                value: totalBytes.map(ByteFormat.string) ?? "—",
                detail: nil
            )
        }
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

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(settings.t("appsModeTitle"))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            VStack(spacing: 6) {
                modeOption(.applicationOnly)
                modeOption(.applicationAndData)
            }
        }
    }

    private func modeOption(_ option: ApplicationUninstallMode) -> some View {
        let selected = mode == option
        return Button {
            mode = option
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.textMuted)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.t(option == .applicationOnly ? "appsModeApplication" : "appsModeData"))
                        .font(Theme.Font.label)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(settings.t(option == .applicationOnly ? "appsModeApplicationDetail" : "appsModeDataDetail"))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.Palette.selection : Theme.Palette.raised, in: .rect(cornerRadius: Theme.Radius.inner))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous)
                    .stroke(selected ? Theme.Palette.accent.opacity(0.45) : Theme.Palette.hairline, lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityLabel(settings.t(option == .applicationOnly ? "appsModeApplication" : "appsModeData"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("applications.mode.\(option.rawValue)")
    }

    private var keptNote: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "archivebox")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.textMuted)
            Text(settings.t("appsRelatedKept"))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var relatedSelection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(settings.t("appsRelatedSelect"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Button(settings.t("selectAll")) {
                    selectedPaths = Set(app.relatedItems.map(\.path))
                }
                .buttonStyle(.plain)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.accent)
                .disabled(isWorking)
                .accessibilityIdentifier("applications.selectAll")
                Button(settings.t("selectNone")) {
                    selectedPaths.removeAll()
                }
                .buttonStyle(.plain)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textMuted)
                .disabled(isWorking)
                .accessibilityIdentifier("applications.selectNone")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if app.relatedItems.isEmpty {
                        Text(settings.t("appsNoRelated"))
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textMuted)
                            .padding(.vertical, Theme.Space.s)
                    } else {
                        ForEach(app.relatedItems) { item in
                            relatedItemRow(item)
                        }
                    }
                }
            }
            .frame(maxHeight: 150)
            if selectedRelated.isEmpty {
                Text(settings.t("appsRelatedNoneSelected"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.warning)
                    .accessibilityIdentifier("applications.related.noneSelected")
            }
        }
    }

    private func relatedItemRow(_ item: RelatedItem) -> some View {
        let selected = selectedPaths.contains(item.path)
        return Button {
            if selected {
                selectedPaths.remove(item.path)
            } else {
                selectedPaths.insert(item.path)
            }
        } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.textMuted)
                Text(settings.t(relatedLabel(item)))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 108, alignment: .leading)
                PathText(path: item.path, font: Theme.Font.caption)
                Spacer(minLength: Theme.Space.s)
                Text(item.bytes.map(ByteFormat.string) ?? "—")
                    .font(Theme.Font.number(size: 11))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityLabel(settings.t(relatedLabel(item)))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("applications.related.\(item.path)")
    }

    private var affected: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(settings.t("affectedLocations"))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    affectedRow(path: app.path, label: settings.t("appBundle"), bytes: app.bytes)
                    if mode == .applicationAndData {
                        ForEach(selectedRelated) { item in
                            affectedRow(
                                path: item.path,
                                label: settings.t(relatedLabel(item)),
                                bytes: item.bytes
                            )
                        }
                    }
                }
            }
            .frame(maxHeight: 96)
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
                        Text(isQuitting
                             ? settings.t("appsQuitFirst")
                             : settings.t("busyDeleting", ["n": "\(1 + selectedRelated.count)"]))
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                Button {
                    onConfirm(mode == .applicationOnly ? [] : selectedRelated.map(\.path), permanent)
                } label: {
                    Text(confirmTitle)
                }
                .buttonStyle(DestructiveButtonStyle())
                .disabled(isWorking || !selectionIsValid)
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
