import DustlessKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var login: LoginItem
    let onClean: () -> Void

    var body: some View {
        List(selection: $store.tierTab) {
            Section("Storage") {
                Label("Free space", systemImage: "internaldrive")
                    .badge(ByteFormat.string(store.report?.freeBefore ?? 0))
                Label("Reclaimable", systemImage: "sparkles")
                    .badge(ByteFormat.string(store.report?.reclaimable ?? 0))
            }

            if let report = store.report {
                Section("Tiers") {
                    ForEach(TierTab.allCases) { tab in
                        tierRow(tab, report: report)
                            .tag(tab)
                    }
                }
            }

            Section("Actions") {
                Button(action: { Task { await store.rescan() } }) {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(store.phase == .scanning || store.phase == .resolvingEngine)

                Button(action: onClean) {
                    Label("Clean selected", systemImage: "trash")
                }
                .disabled(!store.canClean)
            }

            Section("Startup") {
                Toggle(isOn: Binding(
                    get: { login.state.isEnabled },
                    set: { login.setEnabled($0) }
                )) {
                    Label("Launch at login", systemImage: "power")
                }
                .disabled(!login.isSupported)

                if case .unsupported(let reason) = login.state {
                    Text(reason)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = login.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 208, ideal: 224, max: 260)
    }

    private func tierRow(_ tab: TierTab, report: ScanReport) -> some View {
        let items = tab.findings(in: report)
        let bytes = items.reduce(0) { $0 + $1.bytes }
        return HStack(spacing: 6) {
            Image(systemName: tab.symbolName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tab.tint)
            Text(tab.title)
            Spacer(minLength: 4)
            Text("\(items.count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(items.isEmpty ? Color.secondary.opacity(0.7) : tab.tint)
            Text(ByteFormat.string(bytes))
                .font(.system(size: 10.5, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tab.title): \(items.count) items, \(ByteFormat.string(bytes))")
        .accessibilityAddTraits(store.tierTab == tab ? [.isSelected] : [])
    }
}
