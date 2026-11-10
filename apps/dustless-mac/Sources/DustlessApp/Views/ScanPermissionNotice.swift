import AppKit
import SwiftUI

struct ScanPermissionNotice: View {
    @ObservedObject var store: ScanStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        if let content {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                leading(content)
                VStack(alignment: .leading, spacing: 4) {
                    Text(settings.t(content.titleKey))
                        .font(Theme.Font.label)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .accessibilityIdentifier("scan.permission.title")
                    Text(settings.t(content.bodyKey))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("scan.permission.body")
                }
                Spacer(minLength: Theme.Space.s)
                actions(content)
            }
            .padding(Theme.Space.m)
            .background(
                content.waiting ? Theme.Palette.raised : Theme.Palette.warningFill,
                in: .rect(cornerRadius: Theme.Radius.inner)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous)
                    .stroke(
                        content.waiting ? Theme.Palette.hairline : Theme.Palette.warning.opacity(0.3),
                        lineWidth: 1
                    )
            }
        }
    }

    private struct Content {
        let titleKey: String
        let bodyKey: String
        let waiting: Bool
    }

    private var content: Content? {
        switch store.scanPermission {
        case .none:
            nil
        case .waiting:
            Content(
                titleKey: "scanPermissionWaitingTitle",
                bodyKey: "scanPermissionWaitingBody",
                waiting: true
            )
        case .required:
            Content(
                titleKey: "scanPermissionRequiredTitle",
                bodyKey: "scanPermissionRequiredBody",
                waiting: false
            )
        }
    }

    @ViewBuilder
    private func leading(_ content: Content) -> some View {
        if content.waiting {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.Palette.accent)
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.warning)
                .frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private func actions(_ content: Content) -> some View {
        if content.waiting {
            settingsButton
        } else {
            Button(settings.t("rescan")) {
                Task { await store.rescan() }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(store.isBusy)
            .accessibilityIdentifier("scan.permission.retry")
            settingsButton
            Button {
                store.dismissPermissionNotice()
            } label: {
                Text(settings.t("scanPermissionDismiss"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("scan.permission.dismiss")
        }
    }

    private var settingsButton: some View {
        Button(settings.t("scanPermissionOpenSettings")) {
            openPrivacySettings()
        }
        .buttonStyle(SecondaryButtonStyle())
        .accessibilityIdentifier("scan.permission.settings")
    }

    private func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
            ?? URL(string: "x-apple.systempreferences:com.apple.preference.security")!
        NSWorkspace.shared.open(url)
    }
}
