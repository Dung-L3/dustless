import DustlessKit
import SwiftUI

struct OverviewContent: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var net: NetControl
    let router: AppRouter

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.l) {
            if let error = store.engineError {
                engineErrorCard(error)
            }

            if let report = store.report {
                UnscannableNotice(report: report, showsDetail: true, identifier: "overview.unscannable")
                tierStrip(report)
            }

            HStack(alignment: .top, spacing: PanelStyle.Space.l) {
                VStack(alignment: .leading, spacing: PanelStyle.Space.l) {
                    if let report = store.report {
                        topFindings(report)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: PanelStyle.Space.l) {
                    if let blocked = blocked {
                        coverage(blocked)
                    }
                    moduleLines
                }
                .frame(width: 300, alignment: .leading)
            }
        }
    }

    private func engineErrorCard(_ error: L10nText) -> some View {
        HStack(alignment: .top, spacing: PanelStyle.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            EngineErrorMessage(
                text: error,
                retry: { Task { await store.rescan() } },
                retryIdentifier: "overview.retry"
            )
            Spacer(minLength: 0)
        }
        .padding(PanelStyle.Space.m)
        .panelCard(PanelStyle.rowFill)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("overview.engineError")
    }

    private var blocked: (count: Int, bytes: UInt64)? {
        guard let blocked = store.report?.totals.blocked, blocked.count > 0 else { return nil }
        return (blocked.count, blocked.bytes)
    }

    private func tierStrip(_ report: ScanReport) -> some View {
        HStack(spacing: PanelStyle.Space.s) {
            ForEach(TierTab.allCases) { tab in
                tierCard(tab, report: report)
            }
        }
    }

    private func tierCard(_ tab: TierTab, report: ScanReport) -> some View {
        let items = tab.findings(in: report)
        let bytes = items.reduce(0) { $0 + $1.bytes }
        let title = settings.tabTitle(tab)
        return Button {
            store.tierTab = tab
            router.select(.cleanup)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: tab.symbolName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tab.tint)
                    Text(title)
                        .font(PanelFont.emphasis())
                    Spacer(minLength: 0)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ByteFormat.string(bytes))
                        .font(PanelFont.number(.semibold))
                        .foregroundStyle(bytes == 0 ? Color.secondary : Color.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PanelStyle.Space.m)
            .panelCard(PanelStyle.rowFill)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(settings.itemCount(items.count)) · \(ByteFormat.string(bytes))")
        .accessibilityIdentifier("overview.tier.\(tab.rawValue)")
    }

    private func coverage(_ blocked: (count: Int, bytes: UInt64)) -> some View {
        HStack(alignment: .top, spacing: PanelStyle.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.t("overviewCoverage", ["count": settings.itemCount(blocked.count)]))
                    .font(PanelFont.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(ByteFormat.string(blocked.bytes)) · \(settings.t("blockedNotice"))")
                    .font(PanelFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(PanelStyle.Space.m)
        .panelCard(PanelStyle.rowFill)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("overview.blocked")
    }

    private func topFindings(_ report: ScanReport) -> some View {
        let items = Array(report.deletable.sorted { $0.bytes > $1.bytes }.prefix(5))
        return VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            Text(settings.t("findings"))
                .panelSectionHeader()
            ForEach(items) { finding in
                topFindingRow(finding)
            }
        }
        .padding(PanelStyle.Space.m)
        .panelCard()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("overview.findings")
    }

    private func topFindingRow(_ finding: Finding) -> some View {
        Button {
            store.tierTab = tierTab(for: finding.effectiveTier)
            router.select(.cleanup)
        } label: {
            HStack(spacing: PanelStyle.Space.s) {
                TierBadge(tier: finding.effectiveTier, compact: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(finding.ruleId)
                        .font(PanelFont.emphasis())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(RuleText.description(of: finding, lang: settings.language))
                        .font(PanelFont.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(finding.path)
                        .font(PanelFont.mono(10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: PanelStyle.Space.s)
                Text(ByteFormat.string(finding.bytes))
                    .font(PanelFont.number(.semibold))
                    .frame(width: PanelStyle.byteColumnWidth, alignment: .trailing)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("overview.finding.\(finding.ruleId)")
    }

    private func tierTab(for tier: Tier) -> TierTab {
        switch tier {
        case .green: .safe
        case .yellow: .review
        case .red, .blocked: .locked
        }
    }

    private var moduleLines: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            Text(settings.t("modules"))
                .panelSectionHeader()
            moduleLine(.memory, settings.t("memory"), memoryLine, identifier: "memory")
            moduleLine(.network, settings.t("networkTitle"), networkLine, identifier: "network")
            moduleLine(.network, settings.t("awdlTitle"), airDropLine, identifier: "awdl")
        }
        .padding(PanelStyle.Space.m)
        .panelCard()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("overview.modules")
    }

    private func moduleLine(_ module: Module, _ title: String, _ value: String, identifier: String) -> some View {
        HStack(spacing: PanelStyle.Space.s) {
            Image(systemName: module.symbolName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(PanelFont.emphasis())
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: PanelStyle.Space.s)
            Text(value)
                .font(PanelFont.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
            Button(settings.t("overviewView")) { router.select(module) }
                .controlSize(.small)
                .help(title)
                .accessibilityLabel("\(settings.t("overviewView")): \(title)")
                .accessibilityIdentifier("overview.view.\(identifier)")
        }
        .padding(.vertical, PanelStyle.Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.line.\(identifier)")
    }

    private var memoryLine: String {
        guard let memory = store.memoryReport?.memory else {
            return store.memoryPhase == .loading ? settings.t("busyMemory") : "—"
        }
        let label = settings.pressureLabel(memory.pressure)
        return "\(label) (\(memory.pressurePercent)%)"
    }

    private var networkLine: String {
        guard let report = net.report else {
            return net.isLoading ? settings.t("busyNetwork") : "—"
        }
        let iface = report.iface ?? "—"
        let gateway = report.gateway ?? "—"
        return "\(iface) · \(gateway)"
    }

    private var airDropLine: String {
        switch net.awdl.state {
        case .on: settings.t("awdlOnShort")
        case .off: settings.t("awdlOffShort")
        default: settings.t("awdlUnknownShort")
        }
    }
}
