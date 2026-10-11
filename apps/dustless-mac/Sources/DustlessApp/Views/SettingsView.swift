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

                Picker(settings.t("theme"), selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(settings.t(mode.rawValue)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text(settings.t("general"))
            }

            Section {
                Toggle(isOn: Binding(
                    get: { login.state.isEnabled },
                    set: { login.setEnabled($0) }
                )) {
                    Text(settings.t("launchAtLogin"))
                }
                .disabled(!login.isSupported)

                if case .unsupported(let reason) = login.state {
                    Text(settings.t(reason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = login.lastError {
                    Label(settings.text(error), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(settings.t("startup"))
            } footer: {
                Text(settings.t("startupNote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
