import DustlessKit
import SwiftUI

struct OverviewContent: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var net: NetControl
    let router: AppRouter

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if let error = store.engineError {
                engineErrorCard(error)
            }

            if let report = store.report {
                if blockedCount > 0 || report.unscannableSummary.total > 0 {
                    attentionCard(report)
                }
                largestFindings(report)
                moduleShortcuts
            } else if store.isBusy {
                scanningHint
            } else {
                emptyHint
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blockedCount: Int {
        store.report?.totals.blocked.count ?? 0
    }

    private func engineErrorCard(_ error: L10nText) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.warning)
            EngineErrorMessage(
                text: error,
                retry: { Task { await store.rescan() } },
                retryIdentifier: "overview.retry"
            )
            Spacer(minLength: 0)
        }
        .surfaceCard(padding: Theme.Space.m, tone: Theme.Palette.warningFill)
        .accessibilityIdentifier("overview.engineError")
    }

    private func attentionCard(_ report: ScanReport) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.warning)
                Text(settings.t("overviewAttention"))
                    .font(Theme.Font.section)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
            }
            if blockedCount > 0 {
                Text(settings.t("overviewBlocked", ["count": settings.itemCount(blockedCount)]))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            UnscannableNotice(report: report, compact: true, identifier: "overview.unscannable")
        }
        .surfaceCard(padding: Theme.Space.m, tone: Theme.Palette.raised)
        .accessibilityIdentifier("overview.attention")
    }

    private func largestFindings(_ report: ScanReport) -> some View {
        let findings = report.deletable.sorted { $0.bytes > $1.bytes }.prefix(3)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text(settings.t("overviewWhatFound"))
                    .font(Theme.Font.section)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Button(settings.t("menuPickToClean")) {
                    router.select(.cleanup)
                }
                .buttonStyle(.plain)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.accent)
                .accessibilityIdentifier("overview.seeAll")
            }
            if findings.isEmpty {
                Text(settings.t("overviewNothingFound"))
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textMuted)
                    .padding(.vertical, Theme.Space.s)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(findings.enumerated()), id: \.element.id) { index, finding in
                        HStack(spacing: Theme.Space.s) {
                            TierBadge(tier: finding.effectiveTier, compact: true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(RuleText.description(of: finding, lang: settings.language))
                                    .font(Theme.Font.label)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                    .lineLimit(1)
                                PathText(path: finding.path, font: Theme.Font.caption)
                            }
                            Spacer(minLength: Theme.Space.s)
                            Text(ByteFormat.string(finding.bytes))
                                .font(Theme.Font.number(.semibold, size: 12))
                                .foregroundStyle(Theme.Palette.textPrimary)
                        }
                        .padding(.vertical, 6)
                        .staggeredAppear(index)
                    }
                }
            }
        }
        .surfaceCard(padding: Theme.Space.m)
        .accessibilityIdentifier("overview.findings")
    }

    private var moduleShortcuts: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(settings.t("modules"))
                .font(Theme.Font.section)
                .foregroundStyle(Theme.Palette.textPrimary)
            HStack(spacing: Theme.Space.s) {
                ModuleShortcut(
                    title: settings.t("cleanupModule"),
                    detail: cleanupDetail,
                    symbol: "sparkles",
                    action: { router.select(.cleanup) }
                )
                ModuleShortcut(
                    title: settings.t("storage"),
                    detail: storageDetail,
                    symbol: "internaldrive",
                    action: { router.select(.storage) }
                )
                ModuleShortcut(
                    title: settings.t("appsTitle"),
                    detail: appsDetail,
                    symbol: "square.stack.3d.up",
                    action: { router.select(.applications) }
                )
                ModuleShortcut(
                    title: settings.t("memory"),
                    detail: memoryDetail,
                    symbol: "memorychip",
                    action: { router.select(.memory) }
                )
            }
        }
        .accessibilityIdentifier("overview.modules")
    }

    private var cleanupDetail: String {
        guard let report = store.report else { return "—" }
        return "\(settings.itemCount(report.deletable.count)) · \(ByteFormat.string(report.reclaimable))"
    }

    private var storageDetail: String {
        guard let free = store.diskSpace?.available else { return "—" }
        return "\(settings.t("freeNow")) \(ByteFormat.string(free))"
    }

    private var appsDetail: String {
        store.storageApps.isEmpty ? settings.t("appsInstalledShort") : settings.appCount(store.storageApps.count)
    }

    private var memoryDetail: String {
        guard let memory = store.memoryReport?.memory else { return "—" }
        return "\(settings.pressureLabel(memory.pressure)) · \(memory.pressurePercent)%"
    }

    private var scanningHint: some View {
        HStack(spacing: Theme.Space.m) {
            ProgressView().controlSize(.small).tint(Theme.Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.t("scanningShort"))
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(settings.t("busyScanning"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textMuted)
            }
            Spacer()
        }
        .surfaceCard(padding: Theme.Space.m, tone: Theme.Palette.raised)
        .accessibilityIdentifier("overview.scanning")
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(settings.t("overviewNoScan"))
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(settings.t("emptyStateBody"))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textMuted)
        }
        .surfaceCard(padding: Theme.Space.m)
    }
}

private struct ModuleShortcut: View {
    let title: String
    let detail: String
    let symbol: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.Palette.accent)
                Text(title)
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
            .surfaceCard(padding: 0, radius: Theme.Radius.inner, tone: hovered ? Theme.Palette.hover : Theme.Palette.surface)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(title), \(detail)")
    }
}
