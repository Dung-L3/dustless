import DustlessKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: ScanStore
    let onClean: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        List(selection: $store.tierTab) {
            Section(settings.t("storage")) {
                Label(settings.t("freeSpace"), systemImage: "internaldrive")
                    .badge(ByteFormat.string(store.report?.freeBefore ?? 0))
                Label(settings.t("reclaimableMetric"), systemImage: "sparkles")
                    .badge(ByteFormat.string(store.report?.reclaimable ?? 0))
            }

            if let report = store.report {
                Section(settings.t("tiers")) {
                    ForEach(TierTab.allCases) { tab in
                        tierRow(tab, report: report)
                            .tag(tab)
                    }
                }
            }

            Section(settings.t("actions")) {
                Button(action: { Task { await store.rescan() } }) {
                    Label(settings.t("rescan"), systemImage: "arrow.clockwise")
                }
                .disabled(store.phase == .scanning || store.phase == .resolvingEngine)

                Button(action: onClean) {
                    Label(
                        settings.t("cleanSelected", ["amount": ByteFormat.string(store.selectedBytes)]),
                        systemImage: "trash"
                    )
                }
                .disabled(!store.canClean)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 208, ideal: 224, max: 260)
    }

    private func tierRow(_ tab: TierTab, report: ScanReport) -> some View {
        let items = tab.findings(in: report)
        let bytes = items.reduce(0) { $0 + $1.bytes }
        let title = settings.tabTitle(tab)
        return HStack(spacing: 6) {
            Image(systemName: tab.symbolName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tab.tint)
            Text(title)
            Spacer(minLength: 4)
            Text("\(items.count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(items.isEmpty ? Color.secondary.opacity(0.7) : tab.tint)
            Text(ByteFormat.string(bytes))
                .font(.system(size: 10.5, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(settings.t("itemMany", ["n": "\(items.count)"])) · \(ByteFormat.string(bytes))")
        .accessibilityAddTraits(store.tierTab == tab ? [.isSelected] : [])
    }
}
