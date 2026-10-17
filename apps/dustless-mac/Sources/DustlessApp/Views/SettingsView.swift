import DustlessKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var login: LoginItem
    @ObservedObject var awdl: AwdlControl

    var body: some View {
        Form {
            Section {
                Picker(settings.t("language"), selection: $settings.language) {
                    ForEach(Lang.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .accessibilityLabel(settings.t("language"))

                Picker(settings.t("theme"), selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(settings.t(mode.rawValue)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(settings.t("theme"))
                .help(settings.t("themeHelp"))

                Toggle(isOn: $settings.showInDock) {
                    Text(settings.t("showInDock"))
                }
                .help(settings.t("showInDockNote"))
                .accessibilityLabel(settings.t("showInDock"))
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
                    Button(settings.t("awdlRemove")) { Task { await awdl.removePrivilege() } }
                        .disabled(awdl.busy)
                } else {
                    Button(settings.t("awdlInstall")) { Task { await awdl.installPrivilege() } }
                        .disabled(awdl.busy)
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
                HStack(spacing: 6) {
                    Text("Dustless")
                        .font(.system(size: 12, weight: .semibold))
                    Text(version)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Dustless \(version)")
            } header: {
                Text(settings.t("about"))
            }
        }
        .formStyle(.grouped)
        .task { await awdl.refresh() }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?):
            return "\(short) (\(build))"
        default:
            return short ?? build ?? "—"
        }
    }
}
