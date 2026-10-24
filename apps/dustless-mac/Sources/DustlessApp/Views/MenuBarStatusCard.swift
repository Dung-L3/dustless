import DustlessKit
import SwiftUI

struct MenuBarStatusCard: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var net: NetControl

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: PanelStyle.Space.m, alignment: .leading),
                    GridItem(.flexible(), spacing: PanelStyle.Space.m, alignment: .leading),
                ],
                alignment: .leading,
                spacing: PanelStyle.Space.s
            ) {
                ForEach(stats) { stat in
                    PanelStat(label: stat.label, value: stat.value)
                        .help(stat.help ?? stat.label)
                }
            }

            if let consumer = topConsumer {
                Text(consumer)
                    .font(PanelFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(consumer)
                    .accessibilityLabel(consumer)
                    .accessibilityIdentifier("menubar.top-memory")
            }
        }
        .padding(PanelStyle.Space.m)
        .panelCard()
        .accessibilityIdentifier("menubar.status")
    }

    private var topConsumer: String? {
        guard store.memoryPhase == .loaded, let memory = store.memoryReport else { return nil }
        guard let group = memory.processes.groupedByApp().first else { return nil }
        return settings.t("menubar.topConsumer", [
            "name": group.displayName,
            "mem": ByteFormat.string(group.bytes),
        ])
    }

    private struct Stat: Identifiable {
        let label: String
        let value: String
        var help: String?
        var id: String { label }
    }

    private var stats: [Stat] {
        [
            Stat(
                label: settings.t("freeNow"),
                value: freeSpace,
                help: settings.t("freeNowHelp")
            ),
            Stat(
                label: settings.t("reclaimableMetric"),
                value: store.report.map { ByteFormat.string($0.reclaimable) } ?? "—",
                help: settings.t("reclaimableHelp")
            ),
            Stat(label: settings.t("memoryPressure"), value: memoryValue),
            Stat(label: settings.t("networkTitle"), value: networkValue, help: networkHelp),
        ]
    }

    private var freeSpace: String {
        if let report = store.report { return ByteFormat.string(report.freeBefore) }
        if let disk = store.diskSpace { return ByteFormat.string(disk.available) }
        return "—"
    }

    private var memoryValue: String {
        guard let memory = store.memoryReport?.memory else {
            return store.memoryPhase == .loading ? settings.t("busyMemory") : "—"
        }
        return "\(settings.pressureLabel(memory.pressure)) · \(memory.pressurePercent)%"
    }

    private var networkValue: String {
        guard let report = net.report else {
            return net.isLoading ? settings.t("busyNetwork") : "—"
        }
        return "\(report.iface ?? "—") · \(report.gateway ?? "—")"
    }

    private var networkHelp: String? {
        guard let report = net.report else { return nil }
        return "\(settings.t("networkInterface")): \(report.iface ?? "—") · "
            + "\(settings.t("networkGateway")): \(report.gateway ?? "—")"
    }
}
