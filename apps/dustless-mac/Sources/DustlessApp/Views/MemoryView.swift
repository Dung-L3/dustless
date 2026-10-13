import DustlessKit
import SwiftUI

/// Avoid collision with Foundation.NSProcessInfo
typealias MemProcess = DustlessKit.ProcessInfo
typealias MemCategory = DustlessKit.Category

struct MemoryView: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.closeWindow) private var closeWindow

    @State private var killResults: [Int: KillStatus] = [:]
    @State private var isRefreshing = false

    var body: some View {
        let report = store.memoryReport
        VStack(alignment: .leading, spacing: 16) {
            header(report)
            Divider()
            memoryGrid(report)
            Divider()
            processList(report)
        }
        .padding(20)
        .frame(width: 560)
        .background(.regularMaterial)
    }

    private func header(_ report: MemoryReport?) -> some View {
        HStack {
            Text(settings.t("memory"))
                .font(.title2.weight(.semibold))
            Spacer()
            if let report {
                pressureBadge(report)
            }
            Button(action: { closeWindow() }) {
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

    private func pressureBadge(_ report: MemoryReport) -> some View {
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

    private func memoryGrid(_ report: MemoryReport?) -> some View {
        let mem = report?.memory
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MetricRow(label: settings.t("memoryAvailable"), value: mem.map { ByteFormat.string($0.available) } ?? "—")
            MetricRow(label: settings.t("memoryUsed"), value: mem.map { ByteFormat.string($0.used) } ?? "—")
            MetricRow(label: settings.t("memoryTotal"), value: mem.map { ByteFormat.string($0.total) } ?? "—")
            MetricRow(label: settings.t("memoryCompressed"), value: mem.map { ByteFormat.string($0.compressed) } ?? "—")
            MetricRow(label: settings.t("memorySwapUsed"), value: mem.map { ByteFormat.string($0.swapUsed) } ?? "—")
            MetricRow(label: settings.t("memorySwapTotal"), value: mem.map { ByteFormat.string($0.swapTotal) } ?? "—")
        }
    }

    private func processList(_ report: MemoryReport?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(settings.t("memoryProcesses"))
                .font(.headline)

            let topProcesses = Array((report?.processes ?? [])
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

                TableColumn("") { (proc: MemProcess) in
                    stopButton(for: proc)
                }
                .width(min: 44, ideal: 44, max: 44)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .frame(height: 220)
        }
    }

    @ViewBuilder
    private func stopButton(for proc: MemProcess) -> some View {
        let status = killResults[proc.pid]
        if let status {
            statusView(status)
        } else {
            Button(action: { killProcess(pid: proc.pid, force: false, sigkill: false) }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(settings.t("memoryStopProcess"))
            .contextMenu {
                Button(action: { killProcess(pid: proc.pid, force: true, sigkill: true) }) {
                    Label(settings.t("memoryForceStop"), systemImage: "exclamationmark.octagon.fill")
                }
            }
            .disabled(isRefreshing)
        }
    }

    @ViewBuilder
    private func statusView(_ status: KillStatus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: status.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(status.ok ? .green : .red)
            Text(status.ok ? settings.t("memoryStopped") : (status.reason ?? settings.t("memoryStopError")))
                .font(.caption)
                .foregroundStyle(status.ok ? .green : .red)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background((status.ok ? Color.green : Color.red).opacity(0.12), in: .rect(cornerRadius: 4))
        .transition(.opacity.combined(with: .scale))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation { killResults[status.pid] = nil }
            }
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

    private func killProcess(pid: Int, force: Bool, sigkill: Bool) {
        Task {
            isRefreshing = true
            defer { isRefreshing = false }
            do {
                let cli = try DustlessCLI.resolve()
                let result = try await cli.kill(pid: pid, force: force, sigkill: sigkill)
                await MainActor.run {
                    killResults[pid] = KillStatus(pid: pid, ok: result.ok, reason: result.reason)
                }
                if result.ok {
                    await store.fetchMemory()
                }
            } catch {
                await MainActor.run {
                    killResults[pid] = KillStatus(pid: pid, ok: false, reason: error.localizedDescription)
                }
            }
        }
    }
}

private struct KillStatus: Identifiable {
    let id = UUID()
    let pid: Int
    let ok: Bool
    let reason: String?
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