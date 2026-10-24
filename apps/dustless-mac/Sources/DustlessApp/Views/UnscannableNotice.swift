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
                        VStack(alignment: .leading, spacing: 4) {
                            reasonLines
                            ruleList
                        }
                        .padding(.top, PanelStyle.Space.s)
                    } label: {
                        Text(headline(summary))
                            .font(PanelFont.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                            .accessibilityLabel(headline(summary))
                    }
                } else {
                    HStack(alignment: .top, spacing: PanelStyle.Space.s) {
                        symbol
                        VStack(alignment: .leading, spacing: 6) {
                            Text(headline(summary))
                                .font(PanelFont.body)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                                .accessibilityLabel(headline(summary))
                            if !compact {
                                reasonLines
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(compact ? 0 : PanelStyle.Space.m)
            .background(compact ? Color.clear : PanelStyle.rowFill, in: .rect(cornerRadius: PanelStyle.radius))
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(compact && !reasonText.isEmpty ? "\(headline(summary)) · \(reasonText)" : headline(summary))
            .accessibilityHint(compact ? reasonText : "")
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
        settings.t("scan.unscannable.banner", ["count": settings.ruleCount(summary.count)])
    }

    private var counts: [(reason: UnscannableReason, count: Int)] {
        let summary = report.unscannableSummary
        var parts: [(reason: UnscannableReason, count: Int)] = []
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
            parts.append((reason: reason, count: count))
        }
        return parts
    }

    private var reasonText: String {
        counts.map { part in
            settings.t("scan.unscannable.reasonLine", [
                "reason": UnscannableText.reasonLabel(part.reason, lang: settings.language),
                "count": "\(part.count)",
            ])
        }
        .joined(separator: " · ")
    }

    private var reasonLines: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(counts, id: \.reason) { part in
                Text(settings.t("scan.unscannable.reasonLine", [
                    "reason": UnscannableText.reasonLabel(part.reason, lang: settings.language),
                    "count": "\(part.count)",
                ]))
                .font(PanelFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var groups: [(reason: UnscannableReason, ruleIds: [String])] {
        var order: [UnscannableReason] = []
        var map: [UnscannableReason: [String]] = [:]
        for rule in report.unscannable {
            if map[rule.reason] == nil {
                map[rule.reason] = []
                order.append(rule.reason)
            }
            map[rule.reason]?.append(rule.ruleId)
        }
        return order.map { (reason: $0, ruleIds: map[$0] ?? []) }
    }

    private var ruleList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(groups, id: \.reason) { group in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(UnscannableText.reasonLabel(group.reason, lang: settings.language))
                        .font(PanelFont.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 190, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(group.ruleIds.joined(separator: ", "))
                        .font(PanelFont.mono(10))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
