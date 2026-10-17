import DustlessKit
import SwiftUI

/// The Overview dashboard: what this Mac actually looks like right now, and
/// nothing else.
///
/// Every number here is read from a report the engine produced or from the live
/// system — there is no score, no grade, no ring and no "health" percentage,
/// because none of those can be measured from what we have. The view is also
/// deliberately honest about the gaps: a scan that could not verify an item
/// says so, and an unscanned machine says "not scanned" instead of drawing
/// zeros that look like a result.
struct OverviewView: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var net: NetControl
    /// Held, not observed: the dashboard only asks the router to navigate, and
    /// observing it would redraw the whole view on every module switch.
    let router: AppRouter

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The hero number, counting up to the newest report's reclaimable total.
    @State private var shownReclaimable: Double = 0

    var body: some View {
        PanelScaffold {
            PanelHeader(title: settings.t("overviewTitle"), subtitle: provenance)
        } summary: {
            hero
        } filters: {
            // The scaffold's four bands, one of which the dashboard has no use
            // for. Filling it keeps the panel rhythm identical across modules.
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
            // The module lines are the reason to come here without a scan, and
            // a stale number is worse than none: read them when it appears.
            await store.fetchMemory()
            await net.refresh()
        }
    }

    // MARK: - Provenance

    /// Where the numbers came from, in one line. The rule count is derived from
    /// the report's own findings rather than from a hard-coded list: a rule that
    /// found nothing never reaches the user as a claim.
    private var provenance: String? {
        guard let report = store.report else {
            return settings.t("overviewNoScan")
        }
        return settings.t("overviewProvenance", [
            "age": scannedAge,
            "rules": "\(Set(report.findings.map(\.ruleId)).count)",
            "ms": Duration.milliseconds(report.scannedMs),
        ])
    }

    /// Relative to the moment the report landed. It does not tick on its own —
    /// a label that silently grows stale would be a lie in the other direction,
    /// and the next scan redraws it anyway.
    private var scannedAge: String {
        guard let date = store.scannedAt else { return settings.t("overviewAgeNow") }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return settings.t("overviewAgeNow") }
        if seconds < 3600 { return settings.t("overviewAgeMinutes", ["n": "\(Int(seconds / 60))"]) }
        if seconds < 86400 { return settings.t("overviewAgeHours", ["n": "\(Int(seconds / 3600))"]) }
        return settings.t("overviewAgeDays", ["n": "\(Int(seconds / 86400))"])
    }

    // MARK: - Hero

    /// The one number worth the top of the window, with the definition under it
    /// so it is never a bare figure. Same source and same formatter as
    /// `SummaryHeader` — one reclaimable total, said once.
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
            // With no report the definition would be a definition of a number
            // that was never measured, so the line under it says what is true
            // instead: there is nothing here yet.
            Text(store.report == nil ? settings.t("overviewNoScan") : settings.t("reclaimableHelp"))
                .font(PanelFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        // The target, not the value mid-count: a screen reader should not
        // announce a number that is still climbing.
        .accessibilityLabel("\(settings.t("reclaimableMetric")): \(store.report.map { ByteFormat.string($0.reclaimable) } ?? "—")")
    }

    private var reclaimable: UInt64 { store.report?.reclaimable ?? 0 }

    /// Count up on a new report so a changed number is noticed, ease-out over
    /// ~0.45s, and nothing at all when the user asked for less motion.
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

    // MARK: - Free space

    /// Free space as measured — the engine's own reading, or the live volume
    /// read when there is no report yet. After a clean it also carries the
    /// measured delta, which is the only number here that came from deleting
    /// something.
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
        // Freed is a fact about a finished clean, so it only exists once one
        // has happened — never as a projection of the reclaimable total.
        if let apply = store.lastApply {
            stats.append((label: settings.t("freed"), value: ByteFormat.string(apply.freed)))
        }
        return stats
    }

    // MARK: - Tiers

    /// The three tiers with their live counts, each row a door into that tier of
    /// the Cleanup module. The Locked row is here on purpose: what the engine
    /// refuses to delete is part of what the scan found.
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

    // MARK: - Coverage

    /// What the engine could not read. A partial scan that looks complete is
    /// the failure this whole view exists to avoid, so the withheld items are
    /// stated with their size — and nothing is drawn when there are none.
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

    // MARK: - Module lines

    /// One line per module: what it is currently reporting, and a way in. No
    /// verdict, no score — the state the module shows is the whole claim.
    private var moduleLines: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            Text(settings.t("modules"))
                .panelSectionHeader()
            moduleLine(.memory, settings.t("memory"), memoryLine)
            moduleLine(.network, settings.t("networkTitle"), networkLine)
            // The AirDrop radio is part of the Network module, so that is where
            // the row's View action goes.
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
        let label: String = switch memory.pressure {
        case .normal: settings.t("pressureNormal")
        case .warn: settings.t("pressureWarn")
        case .critical: settings.t("pressureCritical")
        }
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

    /// The AirDrop radio's own words, not a paraphrase of them: the module bar
    /// and the Network module say the same three things about it.
    private var airDropLine: String {
        switch net.awdl.state {
        case .on: settings.t("awdlOn")
        case .off: settings.t("awdlOff")
        default: settings.t("awdlUnknown")
        }
    }

    // MARK: - Call to action

    /// The one destructive path, and it opens the existing confirmation sheet —
    /// this view never deletes anything itself. With nothing scanned there is
    /// no count to review, so the same slot offers the scan that produces one.
    /// The count is the *selected* items either way, because a scan pre-selects
    /// nothing and the button must not imply otherwise.
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
