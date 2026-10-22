import DustlessKit
import SwiftUI

struct EngineErrorMessage: View {
    let text: L10nText
    var retry: (() -> Void)? = nil
    var retryIdentifier: String? = nil
    var showsPaths = true

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            Text(headline)
                .font(PanelFont.body)
                .fixedSize(horizontal: false, vertical: true)

            if showsPaths, !paths.isEmpty {
                Text(settings.t("errNotFoundSearched"))
                    .font(PanelFont.caption)
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(paths, id: \.self) { path in
                        Text(path)
                            .font(PanelFont.mono(10))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            if let hint {
                Text(hint)
                    .font(PanelFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let retry {
                Button(settings.t("retry"), action: retry)
                    .controlSize(.small)
                    .axID(retryIdentifier)
            }
        }
        .accessibilityIdentifier("engine.error")
    }

    private var headline: String {
        guard text.key == "errNotFound" else { return settings.text(text) }
        return settings.t("errNotFound", ["list": ""]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var paths: [String] {
        guard text.key == "errNotFound" else { return [] }
        return (text.vars["list"] ?? "")
            .split(separator: ", ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private var hint: String? {
        text.key == "errNotFound" ? settings.t("errNotFoundHint") : nil
    }
}
