import DustlessKit
import SwiftUI

/// Avoid collision with Foundation.NSProcessInfo
typealias MemProcess = DustlessKit.ProcessInfo
typealias MemCategory = DustlessKit.Category

struct MemoryView: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var settings: AppSettings

    @State private var killResults: [Int: KillStatus] = [:]
    /// A kill is in flight; stop buttons are held until the engine answers.
    @State private var isStopping = false
    /// Which row the pointer is over, so the stop button only lights up there.
    @State private var hoveredPID: Int?

    /// The table is a summary, not a full `ps`. The footer says so.
    private static let processLimit = 15

    var body: some View {
        let report = store.memoryReport
        VStack(alignment: .leading, spacing: 16) {
            header(report)
            Divider()
            metrics(report?.memory)
            Divider()
            processes(report)
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 700, minHeight: 560, idealHeight: 660)
        .background(.regularMaterial)
    }

    private func header(_ report: MemoryReport?) -> some View {
        PanelHeader(title: settings.t("memory")) {
            HStack(spacing: 8) {
                if let report {
                    pressureChip(report)
                }
                RefreshButton(isBusy: store.memoryPhase == .loading) {
                    Task { await store.fetchMemory() }
                }
            }
        }
    }

    private func pressureChip(_ report: MemoryReport) -> some View {
        let memory = report.memory
        let (labelKey, color): (String, Color) = {
            switch memory.pressure {
            case .normal: return ("pressureNormal", .green)
            case .warn: return ("pressureWarn", .orange)
            case .critical: return ("pressureCritical", .red)
            }
        }()

        return StatusChip(
            color: color,
            text: "\(settings.t("memoryPressure")): \(settings.t(labelKey)) (\(memory.pressurePercent)%)",
            prominent: true
        )
        .help(settings.t("memoryPressureHelp"))
    }

    private func metrics(_ mem: MemoryInfo?) -> some View {
        func value(_ bytes: UInt64?) -> String { bytes.map(ByteFormat.string) ?? "—" }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            MetricCard(label: settings.t("memoryAvailable"), value: value(mem?.available))
            MetricCard(label: settings.t("memoryUsed"), value: value(mem?.used))
            MetricCard(label: settings.t("memoryTotal"), value: value(mem?.total))
            MetricCard(label: settings.t("memoryCompressed"), value: value(mem?.compressed))
            MetricCard(label: settings.t("memorySwapUsed"), value: value(mem?.swapUsed))
            MetricCard(label: settings.t("memorySwapTotal"), value: value(mem?.swapTotal))
        }
        .padding(10)
        .panelCard()
    }

    private func processes(_ report: MemoryReport?) -> some View {
        let all = report?.processes ?? []
        let top = Array(all.sorted { $0.mem > $1.mem }.prefix(Self.processLimit))

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(settings.t("memoryProcesses"))
                    .panelSectionHeader()
                if all.count > top.count {
                    Text(settings.t("memoryShowingTop", [
                        "shown": "\(top.count)",
                        "total": "\(all.count)",
                    ]))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }

            Table(top) {
                TableColumn(settings.t("memoryProcessName")) { (proc: MemProcess) in
                    Text(proc.name)
                        .font(.system(size: 12.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel(rowDescription(proc))
                }
                .width(min: 160, ideal: 240)

                TableColumn(settings.t("memoryProcessCategory")) { (proc: MemProcess) in
                    StatusChip(
                        color: categoryColor(proc.category),
                        text: settings.t(categoryKey(proc.category))
                    )
                }
                .width(min: 96, ideal: 112)

                TableColumn(settings.t("memoryProcessPID")) { (proc: MemProcess) in
                    Text("\(proc.pid)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .width(min: 56, ideal: 64)

                TableColumn(settings.t("memoryProcessMem")) { (proc: MemProcess) in
                    Text(ByteFormat.string(proc.mem))
                        .font(.system(size: 12.5, weight: .medium, design: .rounded).monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 76, ideal: 88)

                TableColumn(settings.t("actions")) { (proc: MemProcess) in
                    stopButton(for: proc)
                }
                .width(min: 40, ideal: 40, max: 40)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .frame(height: top.isEmpty ? 90 : 250)

            if top.isEmpty {
                Text(settings.t("memoryNoProcesses"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Spoken once for the whole row rather than as four disconnected cells.
    private func rowDescription(_ proc: MemProcess) -> String {
        [
            proc.name,
            settings.t("memoryProcessPID") + " " + "\(proc.pid)",
            settings.t(categoryKey(proc.category)),
            ByteFormat.string(proc.mem),
        ].joined(separator: ", ")
    }

    @ViewBuilder
    private func stopButton(for proc: MemProcess) -> some View {
        if let status = killResults[proc.pid] {
            statusView(status, for: proc)
        } else {
            let hovering = hoveredPID == proc.pid
            Button(action: { killProcess(pid: proc.pid, force: false, sigkill: false) }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(hovering ? Color.red : Color.secondary.opacity(0.8))
                    .frame(width: 24, height: 20)
                    .background(hovering ? Color.red.opacity(0.14) : .clear, in: .rect(cornerRadius: 5))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                hoveredPID = hovering ? proc.pid : (hoveredPID == proc.pid ? nil : hoveredPID)
            }
            .help(settings.t("memoryStopNamed", ["name": proc.name]))
            .accessibilityLabel(settings.t("memoryStopNamed", ["name": proc.name]))
            .contextMenu {
                Button(action: { killProcess(pid: proc.pid, force: true, sigkill: true) }) {
                    Label(
                        settings.t("memoryForceStopNamed", ["name": proc.name]),
                        systemImage: "exclamationmark.octagon.fill"
                    )
                }
            }
            .disabled(isStopping)
        }
    }

    @ViewBuilder
    private func statusView(_ status: KillStatus, for proc: MemProcess) -> some View {
        let tint = status.ok ? Color.green : Color.red
        let label = status.ok
            ? settings.t("memoryStoppedNamed", ["name": proc.name])
            : (status.reason ?? settings.t("memoryStopError"))
        Image(systemName: status.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .help(label)
            .accessibilityLabel(label)
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

    private func categoryColor(_ category: MemCategory) -> Color {
        switch category {
        case .browser: return .blue
        case .editor: return .purple
        case .container: return .teal
        case .lsp: return .orange
        case .other: return .secondary
        }
    }

    private func killProcess(pid: Int, force: Bool, sigkill: Bool) {
        Task {
            isStopping = true
            defer { isStopping = false }
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