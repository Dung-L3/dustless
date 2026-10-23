import DustlessKit
import SwiftUI

struct LargeFileTrashSheet: View {
    let file: LargeFile
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
                HStack(spacing: PanelStyle.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(settings.t("appsTrashTitle"))
                        .font(PanelFont.emphasis(.semibold))
                }
                Text(file.name)
                    .font(PanelFont.emphasis())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(settings.t("largeFilesTrashBody"))
                    .font(PanelFont.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PanelStyle.Space.l)

            Divider()

            AppUninstallRow(name: file.name, path: file.path, bytes: file.size, isApp: false)

            Divider()

            HStack(spacing: PanelStyle.Space.m) {
                Button(settings.t("confirmCancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("storage.trash.cancel")
                Spacer()
                Button(role: .destructive, action: onConfirm) {
                    Text(settings.t("appsMoveToTrash"))
                        .frame(minWidth: 160)
                }
                .tint(DestructiveStyle.red)
                .accessibilityIdentifier("storage.trash.confirm")
            }
            .padding(PanelStyle.Space.l)
            .background(.ultraThinMaterial)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 300)
    }
}

struct UninstallConfirmationSheet: View {
    let app: InstalledApp
    let onCancel: () -> Void
    let onConfirm: (Bool) -> Void

    @EnvironmentObject private var settings: AppSettings

    @State private var permanent = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    AppUninstallRow(
                        name: app.name,
                        path: app.path,
                        bytes: app.bytes,
                        isApp: true
                    )
                    Divider().opacity(0.4).padding(.horizontal, PanelStyle.Space.m)

                    ForEach(app.relatedPaths, id: \.self) { related in
                        AppUninstallRow(
                            name: (related as NSString).lastPathComponent,
                            path: related,
                            bytes: nil,
                            isApp: false
                        )
                        Divider().opacity(0.4).padding(.horizontal, PanelStyle.Space.m)
                    }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 580, idealWidth: 680, minHeight: 380, idealHeight: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            HStack(spacing: PanelStyle.Space.s) {
                Image(systemName: permanent ? "exclamationmark.triangle.fill" : "trash.fill")
                    .foregroundStyle(permanent ? .orange : .secondary)
                Text(settings.t(permanent ? "appsPurgeTitle" : "appsRemoveTitle"))
                    .font(PanelFont.emphasis(.semibold))
            }
            Text(app.name)
                .font(PanelFont.emphasis())
                .lineLimit(1)
                .truncationMode(.middle)
            Text(settings.t(permanent ? "appsPurgeBody" : "appsRemoveBody", ["count": settings.relatedCount(app.relatedPaths.count)]))
                .font(PanelFont.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PanelStyle.Space.l)
    }

    private var footer: some View {
        VStack(spacing: PanelStyle.Space.m) {
            HStack {
                Text(settings.t("totalLabel"))
                    .font(PanelFont.body)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ByteFormat.string(totalBytes))
                    .font(PanelFont.number(.semibold))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(settings.t("confirmTotal", ["amount": ByteFormat.string(totalBytes)]))
            .accessibilityIdentifier("storage.uninstall.total")

            HStack(spacing: PanelStyle.Space.m) {
                Button(settings.t("confirmCancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("storage.uninstall.cancel")
                Spacer()
                if permanent {
                    DestructiveButton {
                        onConfirm(true)
                    } label: {
                        Text(settings.t("appsPurgeAction"))
                            .frame(minWidth: 160)
                    }
                    .accessibilityIdentifier("storage.uninstall.confirm")
                } else {
                    Button {
                        onConfirm(false)
                    } label: {
                        Text(settings.t("appsMoveToTrash"))
                            .frame(minWidth: 160)
                    }
                    .accessibilityIdentifier("storage.uninstall.confirm")
                }
            }

            Button {
                permanent = false
            } label: {
                Text(settings.t("appsKeepReversible"))
            }
            .buttonStyle(.plain)
            .font(PanelFont.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("storage.uninstall.keep")
            .opacity(permanent ? 1 : 0)
            .disabled(!permanent)

            Button {
                permanent = true
            } label: {
                Text(settings.t("appsMakePermanent"))
            }
            .buttonStyle(.plain)
            .font(PanelFont.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("storage.uninstall.makePermanent")
            .opacity(permanent ? 0 : 1)
            .disabled(permanent)
        }
        .padding(PanelStyle.Space.l)
        .background(.ultraThinMaterial)
    }

    private var totalBytes: UInt64 {
        app.bytes
    }
}
