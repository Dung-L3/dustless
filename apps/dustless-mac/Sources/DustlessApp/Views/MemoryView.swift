import DustlessKit
import SwiftUI

/// Avoid collision with Foundation.NSProcessInfo
typealias MemProcess = DustlessKit.ProcessInfo
typealias MemCategory = DustlessKit.Category

struct MemoryView: View {
    let report: MemoryReport
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            memoryGrid
            Divider()
            processList
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 560)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack {
            Text(settings.t("memory"))
                .font(.title2.weight(.semibold))
            Spacer()
            pressureBadge
            Button(action: { NSApp.keyWindow?.close() }) {
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

    private var pressureBadge: some View {
        let pressure = report.memory.pressure
        let percent = report.memory.pressurePercent
        let (labelKey, color): (String, Color) = {
            switch pressure {
            case .normal: return ("pressureNormal", .green)
            case .warn: return ("pressureWarn", .orange)
            case .critical: return ("pressureCritical", .red)
            }
        }()

        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(settings.t("memoryPressure")): \(settings.t(labelKey)) (\(percent)%)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: .capsule)
    }

    private var memoryGrid: some View {
        let mem = report.memory
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MetricRow(label: settings.t("memoryAvailable"), value: ByteFormat.string(mem.available))
            MetricRow(label: settings.t("memoryUsed"), value: ByteFormat.string(mem.used))
            MetricRow(label: settings.t("memoryTotal"), value: ByteFormat.string(mem.total))
            MetricRow(label: settings.t("memoryCompressed"), value: ByteFormat.string(mem.compressed))
            MetricRow(label: settings.t("memorySwapUsed"), value: ByteFormat.string(mem.swapUsed))
            MetricRow(label: settings.t("memorySwapTotal"), value: ByteFormat.string(mem.swapTotal))
        }
    }

    private var processList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(settings.t("memoryProcesses"))
                .font(.headline)

            let topProcesses = Array(report.processes
                .sorted { $0.mem > $1.mem }
                .prefix(15))

            Table(topProcesses) {
                TableColumn(settings.t("memoryProcessName")) { (proc: MemProcess) in
                    Text(proc.name)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 120, ideal: 180)

                TableColumn(settings.t("memoryProcessCategory")) { (proc: MemProcess) in
                    Text(settings.t(categoryKey(proc.category)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 80)

                TableColumn(settings.t("memoryProcessPID")) { (proc: MemProcess) in
                    Text("\(proc.pid)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .width(min: 50, ideal: 70)

                TableColumn(settings.t("memoryProcessMem")) { (proc: MemProcess) in
                    Text(ByteFormat.string(proc.mem))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                .width(min: 70, ideal: 90)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .frame(height: 220)
        }
    }

    private func categoryKey(_ category: MemCategory) -> String {
        switch category {
        case .browser: return "categoryBrowser"
        case .editor: return "categoryEditor"
        case .container: return "categoryContainer"
        case .lsp: return "categoryLSP"
        case .other: return "categoryOther"
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(settings.t("done")) {
                NSApp.keyWindow?.close()
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