import DustlessKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var login: LoginItem
    @ObservedObject var awdl: AwdlControl

    @State private var engineVersion: String?
    @State private var pendingPrivilege = false

    @EnvironmentObject private var localized: AppSettings

    var body: some View {
        Form {
            Section {
                Picker(settings.t("language"), selection: $settings.language) {
                    ForEach(Lang.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .accessibilityLabel(settings.t("language"))
                .accessibilityIdentifier("settings.language")

                Picker(settings.t("theme"), selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(settings.t(mode.rawValue)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(settings.t("theme"))
                .help(settings.t("themeHelp"))
                .accessibilityIdentifier("settings.appearance")

                Toggle(isOn: $settings.showInDock) {
                    Text(settings.t("showInDock"))
                }
                .help(settings.t("showInDockNote"))
                .accessibilityLabel(settings.t("showInDock"))
                .accessibilityIdentifier("settings.showInDock")
            } header: {
                Text(settings.t("general"))
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.t("themeNote"))
                    Text(settings.t("showInDockNote"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { login.state.isEnabled },
                    set: { login.setEnabled($0) }
                )) {
                    Text(settings.t("launchAtLogin"))
                }
                .disabled(!login.isSupported)
                .help(settings.t("launchAtLoginHelp"))
                .accessibilityLabel(settings.t("launchAtLogin"))
                .accessibilityIdentifier("settings.launchAtLogin")

                if case .unsupported(let reason) = login.state {
                    Label(settings.t(reason), systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if case .requiresApproval = login.state {
                    Label(settings.t("loginRequiresApproval"), systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(settings.t("loginRequiresApproval"))
                }

                if let error = login.lastError {
                    Label(settings.text(error), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(settings.t("settingsLoginError"))
                }
            } header: {
                Text(settings.t("startup"))
            } footer: {
                Text(settings.t("startupNote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if awdl.privilegeInstalled {
                    Label(settings.t("awdlInstalled"), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.awdl.installed")
                    Button(settings.t("awdlRemove")) { Task { await awdl.removePrivilege() } }
                        .disabled(awdl.busy)
                        .accessibilityIdentifier("settings.awdl.remove")
                } else {
                    Button(settings.t("awdlInstall")) { pendingPrivilege = true }
                        .disabled(awdl.busy)
                        .help(settings.t("awdlPrivilegeExplain"))
                        .accessibilityLabel(settings.t("awdlInstall"))
                        .accessibilityHint(settings.t("awdlPrivilegeExplain"))
                        .accessibilityIdentifier("settings.awdl.install")
                    Text(settings.t("awdlPrivilegeExplain"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.awdl.explain")
                }

                if let error = awdl.error {
                    Label(settings.text(error), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(settings.t("awdlTitle"))
                }
            } header: {
                Text(settings.t("awdlTitle"))
            } footer: {
                Text(settings.t("awdlNote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent(settings.t("versionLabel")) {
                    Text(appVersion)
                        .font(.system(size: 11, design: .monospaced))
                }
                LabeledContent(settings.t("buildLabel")) {
                    Text(appBuild)
                        .font(.system(size: 11, design: .monospaced))
                }
                LabeledContent(settings.t("engineVersionLabel")) {
                    Text(engineVersion ?? "—")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(engineVersion == nil ? Color.secondary : Color.primary)
                }
                if showsMismatch {
                    Label(settings.t("engineVersionMismatch"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.version.mismatch")
                }
            } header: {
                Text(settings.t("about"))
            }
        }
        .formStyle(.grouped)
        .task {
            await awdl.refresh()
            engineVersion = await EngineVersion.read()
        }
        .awdlPrivilegeConfirm(isPresented: $pendingPrivilege) {
            pendingPrivilege = false
            Task { await awdl.installPrivilege() }
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    private var showsMismatch: Bool {
        guard let engineVersion, engineVersion != "—" else { return false }
        return engineVersion != appVersion
    }
}
