import DustlessKit
import SwiftUI

struct UnscannableNotice: View {
    let report: ScanReport
    var showsDetail = false
    var compact = false
    var identifier: String? = nil

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        if let summary {
            Group {
                if showsDetail {
                    DisclosureGroup {
                        ruleList
                    } label: {
                        Text(headline(summary))
                            .font(PanelFont.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                } else {
                    HStack(alignment: .top, spacing: PanelStyle.Space.s) {
                        symbol
                        Text(headline(summary))
                            .font(PanelFont.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(compact ? 0 : PanelStyle.Space.m)
            .background(compact ? Color.clear : PanelStyle.rowFill, in: .rect(cornerRadius: PanelStyle.radius))
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(headline(summary))
            .accessibilityLabel(headline(summary))
            .axID(identifier)
        }
    }

    private var symbol: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    private var summary: (count: Int, reasonLabels: [String])? {
        UnscannableText.bannerParts(report: report, lang: settings.language)
    }

    private func headline(_ summary: (count: Int, reasonLabels: [String])) -> String {
        settings.t("scan.unscannable.banner", [
            "count": "\(summary.count)",
            "reasons": reasonCounts,
        ])
    }

    private var reasonCounts: String {
        let summary = report.unscannableSummary
        var parts: [String] = []
        for reason in UnscannableReason.allCases {
            let count: Int
            switch reason {
            case .absent: count = summary.absent
            case .noAccess: count = summary.noAccess
            case .notSupported: count = summary.notSupported
            case .error: count = summary.error
            case .red: count = summary.red
            case .protected: count = summary.protected
            }
            guard count > 0 else { continue }
            parts.append("\(UnscannableText.reasonLabel(reason, lang: settings.language)) (\(count))")
        }
        return parts.joined(separator: ", ")
    }

    private var ruleList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(report.unscannable, id: \.ruleId) { rule in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(rule.ruleId)
                            .font(PanelFont.mono(10.5))
                            .textSelection(.enabled)
                        Text(UnscannableText.reasonLabel(rule.reason, lang: settings.language))
                            .font(PanelFont.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, PanelStyle.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 160)
    }
}
