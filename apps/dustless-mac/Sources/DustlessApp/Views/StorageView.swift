import DustlessKit
import SwiftUI

struct StorageView: View {
    let space: DiskSpace
    let reclaimable: UInt64?
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            metricsGrid
            usageBar
            if let reclaimable {
                Divider()
                reclaimableSection(reclaimable)
            }
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 560)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack {
            Text(settings.t("storage"))
                .font(.title2.weight(.semibold))
            if let name = space.volumeName, !name.isEmpty {
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(settings.t("close"))
            .accessibilityLabel(settings.t("close"))
        }
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MetricRow(label: settings.t("diskVolume"), value: space.volumeName ?? settings.t("diskVolume"))
            MetricRow(label: settings.t("diskTotal"), value: ByteFormat.string(space.total))
            MetricRow(label: settings.t("diskUsed"), value: ByteFormat.string(space.used))
            MetricRow(label: settings.t("diskFree"), value: ByteFormat.string(space.free))
        }
    }

    private var usageBar: some View {
        ProgressView(value: Double(space.used), total: Double(space.total))
            .frame(height: 8)
    }

    private func reclaimableSection(_ reclaimable: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(settings.t("reclaimableMetric"))
                    .font(.headline)
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(settings.t("reclaimableHelp"))
            }
            Text(ByteFormat.string(reclaimable))
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
                .foregroundStyle(.primary)
            Text(settings.t("storageNote"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(settings.t("done")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct MetricRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}