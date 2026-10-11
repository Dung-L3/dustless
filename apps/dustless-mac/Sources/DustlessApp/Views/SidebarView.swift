import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var login: LoginItem
    let onOpenWindow: () -> Void
    let onClean: () -> Void

    var body: some View {
        List {
            Section("Storage") {
                Label("Free space", systemImage: "internaldrive")
                    .badge(ByteFormat.string(store.report?.freeBefore ?? 0))
                Label("Reclaimable", systemImage: "sparkles")
                    .badge(ByteFormat.string(store.report?.reclaimable ?? 0))
            }

            if let report = store.report {
                Section("Tiers") {
                    tierRow("Safe", .green, count: report.totals.green.count, bytes: report.totals.green.bytes)
                    tierRow("Review", .yellow, count: report.totals.yellow.count, bytes: report.totals.yellow.bytes)
                    tierRow("Protected", .red, count: report.totals.red.count, bytes: report.totals.red.bytes)
                    tierRow("Locked", .blocked, count: report.totals.blocked.count, bytes: report.totals.blocked.bytes)
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

                Button(action: onOpenWindow) {
                    Label("Open Dustless", systemImage: "macwindow")
                }
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

    private func tierRow(_ title: String, _ tier: Tier, count: Int, bytes: UInt64) -> some View {
        HStack(spacing: 6) {
            Image(systemName: tier.symbolName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint(for: tier))
            Text(title)
            Spacer(minLength: 4)
            Text(ByteFormat.string(bytes))
                .font(.system(size: 10.5, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(count) items, \(ByteFormat.string(bytes))")
    }

    private func tint(for tier: Tier) -> Color {
        switch tier {
        case .green: .green
        case .yellow: .orange
        case .red: .red
        case .blocked: .secondary
        }
    }
}
