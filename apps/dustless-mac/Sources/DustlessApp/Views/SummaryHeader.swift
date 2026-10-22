import DustlessKit
import SwiftUI

struct SummaryHeader: View {
    let report: ScanReport?
    var tier: TierTab = .safe
    let isScanning: Bool
    let onRescan: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: PanelStyle.Space.m) {
                Text(settings.t("cleanupModule"))
                    .font(PanelFont.title)
                    .accessibilityIdentifier("cleanup.title")
                Text(tierLine)
                    .font(PanelFont.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: PanelStyle.Space.m)
                rescanButton
            }

            HStack(alignment: .center, spacing: PanelStyle.Space.l) {
                metric(
                    title: settings.t("reclaimableMetric"),
                    value: report.map { ByteFormat.string($0.reclaimable) } ?? "—",
                    symbol: "sparkles",
                    tint: .accentColor
                )
                .help(settings.t("reclaimableHelp"))

                metric(
                    title: settings.t("freeNow"),
                    value: report.map { ByteFormat.string($0.freeBefore) } ?? "—",
                    symbol: "internaldrive",
                    tint: .secondary
                )
                .help(settings.t("freeNowHelp"))

                if let report {
                    metric(
                        title: settings.t("scanned"),
                        value: Duration.milliseconds(report.scannedMs),
                        symbol: "clock",
                        tint: .secondary
                    )
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, PanelStyle.Space.l)
        .padding(.vertical, PanelStyle.Space.m)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var tierLine: String {
        let count = report.map { tier.findings(in: $0).count } ?? 0
        return "\(settings.tabTitle(tier)) · \(settings.itemCount(count))"
    }

    private var scanLabel: String {
        report == nil ? settings.t("scanNow") : settings.t("rescan")
    }

    private var rescanButton: some View {
        Button(action: onRescan) {
            HStack(spacing: 6) {
                if isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(isScanning ? settings.t("scanningShort") : scanLabel)
            }
        }
        .disabled(isScanning)
        .help(settings.t("rescanHelp"))
        .accessibilityIdentifier("cleanup.rescan")
    }

    private func metric(title: String, value: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
                Text(title.uppercased())
                    .font(PanelFont.caption)
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(PanelFont.hero)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}
