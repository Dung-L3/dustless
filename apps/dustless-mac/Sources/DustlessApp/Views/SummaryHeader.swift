import DustlessKit
import SwiftUI

struct SummaryHeader: View {
    let report: ScanReport?
    let isScanning: Bool
    let onRescan: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(settings.t("cleanupModule"))
                        .font(Theme.Font.title)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .accessibilityIdentifier("cleanup.title")
                    Text(settings.t("cleanupSubtitle"))
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer(minLength: Theme.Space.m)
                Button(action: onRescan) {
                    HStack(spacing: 6) {
                        if isScanning {
                            ProgressView().controlSize(.small).scaleEffect(0.65).frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isScanning ? settings.t("scanningShort") : settings.t("rescan"))
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isScanning)
                .help(settings.t("rescanHelp"))
                .accessibilityIdentifier("cleanup.rescan")
            }

            HStack(spacing: Theme.Space.m) {
                MetricTile(
                    label: settings.t("reclaimableMetric"),
                    value: report.map { ByteFormat.string($0.reclaimable) } ?? "—",
                    detail: nil,
                    tone: .accent,
                    identifier: "cleanup.reclaimable"
                )
                MetricTile(
                    label: settings.t("freeNow"),
                    value: report.map { ByteFormat.string($0.freeBefore) } ?? "—",
                    detail: nil,
                    identifier: "cleanup.free"
                )
                MetricTile(
                    label: settings.t("scanned"),
                    value: report.map { Duration.milliseconds($0.scannedMs) } ?? "—",
                    detail: nil,
                    identifier: "cleanup.scanned"
                )
            }
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.top, Theme.Space.page)
    }
}
