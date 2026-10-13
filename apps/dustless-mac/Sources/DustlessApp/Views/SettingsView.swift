import DustlessKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var login: LoginItem

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
            } header: {
                Text(settings.t("general"))
            } footer: {
                Text(settings.t("themeNote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
