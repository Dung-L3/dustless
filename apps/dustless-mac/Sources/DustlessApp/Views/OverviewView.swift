import DustlessKit
import SwiftUI

struct OverviewView: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var net: NetControl
    let router: AppRouter

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        PanelScaffold {
            PanelHeader(title: settings.t("overviewTitle"), subtitle: provenance, identifier: "overview.header") {
                cta
            }
        } summary: {
            hero
        } filters: {
            EmptyView()
        } content: {
            OverviewContent(store: store, net: net, router: router)
        }
        .task {
            await store.ensureMemory()
            await net.refreshIfStale()
            await store.fetchStorage()
        }
    }

    private var provenance: String {
        settings.provenance(store.report, scannedAt: store.scannedAt, engineFailed: store.engineError != nil)
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: PanelStyle.Space.l) {
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
                Text(store.report == nil ? "—" : ByteFormat.string(reclaimable))
                    .font(PanelFont.hero)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(heroHint)
                    .font(PanelFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(settings.t("reclaimableMetric")): \(store.report.map { ByteFormat.string($0.reclaimable) } ?? "—")")
            .accessibilityIdentifier("overview.hero")

            VStack(alignment: .trailing, spacing: PanelStyle.Space.s) {
                PanelStat(label: settings.t("selectedMetric"), value: selectedValue)
                    .help(selectedHelp)
                    .accessibilityIdentifier("overview.selected")
                PanelStat(label: settings.t("freeNow"), value: freeValue)
                    .help(settings.t("freeNowHelp"))
                    .accessibilityIdentifier("overview.freeSpace")
            }
            .frame(width: 190, alignment: .trailing)
        }
    }

    private var reclaimable: UInt64 { store.report?.reclaimable ?? 0 }

    private var selectedValue: String {
        store.selectedBytes > 0 ? ByteFormat.string(store.selectedBytes) : "—"
    }

    private var selectedHelp: String {
        store.selectedFindings.isEmpty
            ? settings.t("selectedNone")
            : settings.itemCount(store.selectedFindings.count)
    }

    private var freeValue: String {
        let free = store.report?.freeBefore ?? store.diskSpace?.available
        return free.map(ByteFormat.string) ?? "—"
    }

    private var heroHint: String {
        if store.report != nil { return settings.t("reclaimableHelp") }
        return store.engineError == nil ? settings.t("overviewNoScan") : settings.t("engineUnavailable")
    }

    @ViewBuilder
    private var cta: some View {
        if store.report == nil {
            if store.engineError == nil {
                Button {
                    Task { await store.rescan() }
                } label: {
                    HStack(spacing: 6) {
                        if store.isBusy {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        }
                        Text(store.isBusy ? settings.t("scanningShort") : settings.t("scanNow"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isBusy)
                .help(settings.t("rescanHelp"))
                .accessibilityIdentifier("overview.scan")
            }
        } else if store.selectedFindings.isEmpty {
            Button {
                router.select(.cleanup)
            } label: {
                Text(settings.t("menuPickToClean"))
            }
            .buttonStyle(.borderedProminent)
            .help(settings.t("menuPickToClean"))
            .accessibilityIdentifier("overview.pick")
        } else {
            Button {
                router.select(.cleanup)
                store.showingConfirmation = true
            } label: {
                Text(settings.t("reviewAndDelete"))
            }
            .buttonStyle(.borderedProminent)
            .disabled(!store.canClean)
            .help(settings.t("reviewAndDeleteHelp"))
            .accessibilityLabel(settings.t("overviewReview", [
                "count": settings.itemCount(store.selectedFindings.count),
                "size": ByteFormat.string(store.selectedBytes),
            ]))
            .accessibilityIdentifier("overview.review")
        }
    }
}
