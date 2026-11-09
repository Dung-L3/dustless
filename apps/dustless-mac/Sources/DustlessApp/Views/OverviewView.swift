import DustlessKit
import SwiftUI

struct OverviewView: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var net: NetControl
    let router: AppRouter

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        PanelScaffold {
            PanelHeader(
                title: settings.t("overviewTitle"),
                subtitle: provenance,
                identifier: "overview.header"
            ) {
                cta
            }
        } summary: {
            hero
        } filters: {
            EmptyView()
        } content: {
            ScrollView {
                OverviewContent(store: store, net: net, router: router)
            }
            .scrollIndicators(.automatic)
        }
        .task {
            await store.ensureMemory()
            await net.refreshIfStale()
            await store.fetchStorage()
        }
    }

    private var provenance: String {
        if store.report == nil, store.isBusy { return settings.t("scanningShort") }
        return settings.provenance(store.report, scannedAt: store.scannedAt, engineFailed: store.engineError != nil)
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.Palette.accent)
                    Text(settings.t("reclaimableMetric").uppercased())
                        .font(Theme.Font.micro)
                        .tracking(0.6)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Text(store.report == nil ? "—" : ByteFormat.string(reclaimable))
                    .font(Theme.Font.display)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(heroHint)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if let apply = store.lastApply {
                    Text(settings.t("resultSummary", [
                        "freed": ByteFormat.string(apply.freed),
                        "elapsed": Duration.milliseconds(apply.elapsedMs),
                        "free": ByteFormat.string(apply.freeAfter),
                    ]))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(settings.t("reclaimableMetric")): \(store.report.map { ByteFormat.string($0.reclaimable) } ?? "—")")
            .accessibilityIdentifier("overview.hero")

            HStack(spacing: Theme.Space.m) {
                MetricTile(
                    label: settings.t("selectedMetric"),
                    value: selectedValue,
                    detail: selectedHelp,
                    identifier: "overview.selected"
                )
                MetricTile(
                    label: settings.t("freeNow"),
                    value: freeValue,
                    detail: nil,
                    identifier: "overview.freeSpace"
                )
            }
            .frame(width: 330)
        }
    }

    private var reclaimable: UInt64 { store.report?.reclaimable ?? 0 }

    private var selectedValue: String {
        store.selectedBytes > 0 ? ByteFormat.string(store.selectedBytes) : "—"
    }

    private var selectedHelp: String {
        store.selectedFindings.isEmpty ? settings.t("selectedNone") : settings.itemCount(store.selectedFindings.count)
    }

    private var freeValue: String {
        let free = store.report?.freeBefore ?? store.diskSpace?.available
        return free.map(ByteFormat.string) ?? "—"
    }

    private var heroHint: String {
        if store.report != nil { return settings.t("reclaimableHelp") }
        if store.isBusy { return settings.t("busyScanning") }
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
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                        }
                        Text(store.isBusy ? settings.t("scanningShort") : settings.t("scanNow"))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(store.isBusy)
                .help(settings.t("rescanHelp"))
                .accessibilityIdentifier("overview.scan")
            }
        } else if store.selectedFindings.isEmpty {
            if store.safeCleanFindings.isEmpty {
                Button {
                    router.select(.cleanup)
                } label: {
                    Text(settings.t("menuPickToClean"))
                }
                .buttonStyle(PrimaryButtonStyle())
                .help(settings.t("menuPickToClean"))
                .accessibilityIdentifier("overview.pick")
            } else {
                Button {
                    store.tierTab = .safe
                    store.selectQuickClean()
                    router.select(.cleanup)
                    presentConfirmation()
                } label: {
                    Text(settings.t("menubar.cleanSafely", [
                        "items": settings.itemCount(store.safeCleanFindings.count),
                        "size": ByteFormat.string(store.safeCleanBytes),
                    ]))
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(store.isBusy || store.phase != .ready)
                .help(settings.t("menubar.cleanSafelyHelp"))
                .accessibilityHint(settings.t("menubar.cleanSafelyHelp"))
                .accessibilityIdentifier("overview.cleanSafely")
            }
        } else {
            Button {
                router.select(.cleanup)
                presentConfirmation()
            } label: {
                Text(settings.t("reviewAndDelete"))
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!store.canClean)
            .help(settings.t("reviewAndDeleteHelp"))
            .accessibilityLabel(settings.t("overviewReview", [
                "count": settings.itemCount(store.selectedFindings.count),
                "size": ByteFormat.string(store.selectedBytes),
            ]))
            .accessibilityIdentifier("overview.review")
        }
    }

    private func presentConfirmation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            store.showingConfirmation = true
        }
    }
}
