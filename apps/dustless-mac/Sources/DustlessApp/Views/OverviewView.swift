import DustlessKit
import SwiftUI

struct OverviewView: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var net: NetControl
    let router: AppRouter

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var shownReclaimable: Double = 0

    var body: some View {
        PanelScaffold {
            PanelHeader(title: settings.t("overviewTitle"), subtitle: provenance)
        } summary: {
            hero
        } filters: {
            EmptyView()
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: PanelStyle.Space.l) {
                    if !freeStats.isEmpty { freeSpace }
                    if let report = store.report { tiers(report) }
                    if let blocked = blocked { coverage(blocked) }
                    moduleLines
                    cta
                }
            }
        }
        .task(id: reclaimable) { await countUp(to: Double(reclaimable)) }
        .task {
            await store.ensureMemory()
            await net.refreshIfStale()
            await store.fetchStorage()
        }
    }

    private var provenance: String {
        settings.provenance(store.report, scannedAt: store.scannedAt)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.xs) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                Text(settings.t("reclaimableMetric").uppercased())
                    .font(PanelFont.caption)
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
            }
            Text(store.report == nil ? "—" : ByteFormat.string(UInt64(shownReclaimable)))
                .font(PanelFont.hero)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(store.report == nil ? settings.t("overviewNoScan") : settings.t("reclaimableHelp"))
                .font(PanelFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(settings.t("reclaimableMetric")): \(store.report.map { ByteFormat.string($0.reclaimable) } ?? "—")")
    }

    private var reclaimable: UInt64 { store.report?.reclaimable ?? 0 }

    private func countUp(to target: Double) async {
        guard !reduceMotion, target > 0, shownReclaimable < target else {
            shownReclaimable = target
            return
        }
        let steps = 30
        for step in 1...steps {
            let progress = Double(step) / Double(steps)
            shownReclaimable = target * (1 - pow(1 - progress, 3))
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    private var freeSpace: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            PanelStatStrip(stats: freeStats)
            if let apply = store.lastApply {
                Text(settings.t("resultSummary", [
                    "freed": ByteFormat.string(apply.freed),
                    "elapsed": Duration.milliseconds(apply.elapsedMs),
                    "free": ByteFormat.string(apply.freeAfter),
                ]))
                .font(PanelFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var freeStats: [(label: String, value: String)] {
        let free = store.report?.freeBefore ?? store.diskSpace?.available
        var stats: [(label: String, value: String)] = []
        if let free {
            stats.append((label: settings.t("freeNow"), value: ByteFormat.string(free)))
        }
        if let apply = store.lastApply {
            stats.append((label: settings.t("freed"), value: ByteFormat.string(apply.freed)))
        }
        return stats
    }

    private func tiers(_ report: ScanReport) -> some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            Text(settings.t("tiers"))
                .panelSectionHeader()
            ForEach(TierTab.allCases) { tab in
                tierRow(tab, report: report)
            }
        }
        .padding(PanelStyle.Space.m)
        .panelCard()
    }

    private func tierRow(_ tab: TierTab, report: ScanReport) -> some View {
        let items = tab.findings(in: report)
        let bytes = items.reduce(0) { $0 + $1.bytes }
        let title = settings.tabTitle(tab)
        return Button {
            store.tierTab = tab
            router.select(.cleanup)
        } label: {
            HStack(spacing: PanelStyle.Space.s) {
                Image(systemName: tab.symbolName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tab.tint)
                    .frame(width: 14)
                Text(title)
                    .font(PanelFont.emphasis())
                Spacer(minLength: PanelStyle.Space.s)
                Text(settings.t("itemMany", ["n": "\(items.count)"]))
                    .font(PanelFont.number())
                    .foregroundStyle(.secondary)
                Text(ByteFormat.string(bytes))
                    .font(PanelFont.number(.semibold))
                    .frame(minWidth: PanelStyle.byteColumnWidth, alignment: .trailing)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(settings.t("itemMany", ["n": "\(items.count)"])) · \(ByteFormat.string(bytes))")
    }

    private var blocked: (count: Int, bytes: UInt64)? {
        guard let blocked = store.report?.totals.blocked, blocked.count > 0 else { return nil }
        return (blocked.count, blocked.bytes)
    }

    private func coverage(_ blocked: (count: Int, bytes: UInt64)) -> some View {
        HStack(alignment: .top, spacing: PanelStyle.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.t("overviewCoverage", ["n": "\(blocked.count)"]))
                    .font(PanelFont.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(ByteFormat.string(blocked.bytes)) · \(settings.t("blockedNotice"))")
                    .font(PanelFont.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(PanelStyle.Space.m)
        .panelCard(PanelStyle.rowFill)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var moduleLines: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            Text(settings.t("modules"))
                .panelSectionHeader()
            moduleLine(.memory, settings.t("memory"), memoryLine)
            moduleLine(.network, settings.t("networkTitle"), networkLine)
            moduleLine(.network, settings.t("awdlTitle"), airDropLine)
        }
        .padding(PanelStyle.Space.m)
        .panelCard()
    }

    private func moduleLine(_ module: Module, _ title: String, _ value: String) -> some View {
        HStack(spacing: PanelStyle.Space.s) {
            Image(systemName: module.symbolName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(PanelFont.emphasis())
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
        }
        .padding(.vertical, PanelStyle.Space.xs)
        .accessibilityElement(children: .contain)
    }

    private var memoryLine: String {
        guard let memory = store.memoryReport?.memory else {
            return store.memoryPhase == .loading ? settings.t("busyMemory") : "—"
        }
        let label = settings.pressureLabel(memory.pressure)
        return "\(settings.t("memoryPressure")): \(label) (\(memory.pressurePercent)%)"
    }

    private var networkLine: String {
        guard let report = net.report else {
            return net.isLoading ? settings.t("busyNetwork") : "—"
        }
        let iface = report.iface ?? "—"
        let gateway = report.gateway ?? "—"
        return "\(settings.t("networkInterface")): \(iface) · \(settings.t("networkGateway")): \(gateway)"
    }

    private var airDropLine: String {
        switch net.awdl.state {
        case .on: settings.t("awdlOn")
        case .off: settings.t("awdlOff")
        default: settings.t("awdlUnknown")
        }
    }

    private var cta: some View {
        HStack {
            Spacer(minLength: 0)
            if store.report == nil {
                Button {
                    Task { await store.rescan() }
                } label: {
                    Text(settings.t("scanNow"))
                        .frame(minWidth: 190)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isScanning)
                .help(settings.t("rescanHelp"))
            } else {
                Button {
                    router.select(.cleanup)
                    store.showingConfirmation = true
                } label: {
                    Text(store.selectedFindings.isEmpty
                         ? settings.t("selectedNone")
                         : settings.t("overviewReview", [
                             "n": "\(store.selectedFindings.count)",
                             "size": ByteFormat.string(store.selectedBytes),
                         ]))
                        .frame(minWidth: 190)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!store.canClean)
                .help(settings.t("reviewAndDeleteHelp"))
            }
        }
    }

    private var isScanning: Bool { store.isBusy }
}