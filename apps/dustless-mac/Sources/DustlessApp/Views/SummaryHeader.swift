import DustlessKit
import SwiftUI

struct SummaryHeader: View {
    let report: ScanReport?
    let isScanning: Bool
    let onRescan: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            metric(
                title: "Reclaimable",
                value: ByteFormat.string(report?.reclaimable ?? 0),
                symbol: "sparkles",
                tint: .accentColor
            )
            .help("Green plus yellow findings, the total the engine may reclaim.")

            metric(
                title: "Free now",
                value: ByteFormat.string(report?.freeBefore ?? 0),
                symbol: "internaldrive",
                tint: .secondary
            )
            .help("Free space on the volume holding your home directory, measured by the engine.")

            if let report {
                metric(
                    title: "Scanned",
                    value: Duration.milliseconds(report.scannedMs),
                    symbol: "clock",
                    tint: .secondary
                )
            }

            Spacer(minLength: 12)

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
                    Text(isScanning ? "Scanning…" : "Rescan")
                }
            }
            .disabled(isScanning)
            .keyboardShortcut("r", modifiers: .command)
            .help("Rescan now (⌘R)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
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
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}
