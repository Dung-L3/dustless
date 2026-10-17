import DustlessKit
import SwiftUI

struct SummaryHeader: View {
    let report: ScanReport?
    let isScanning: Bool
    let onRescan: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
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

            Spacer(minLength: PanelStyle.Space.m)

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
                    Text(isScanning ? settings.t("scanningShort") : settings.t("rescan"))
                }
            }
            .disabled(isScanning)
            .help(settings.t("rescanHelp"))
        }
        .padding(.horizontal, PanelStyle.Space.l)
        .padding(.vertical, PanelStyle.Space.m)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider() }
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