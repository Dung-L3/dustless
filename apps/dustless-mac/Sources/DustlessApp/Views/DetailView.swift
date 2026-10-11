import DustlessKit
import SwiftUI

struct DetailView: View {
    @ObservedObject var store: ScanStore
    let onClean: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let message = store.busyMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let error = store.engineError {
                EngineErrorView(message: error) { Task { await store.rescan() } }
            } else if let report = store.report {
                tierContent(report)
            } else {
                EmptyStateView {
                    Task { await store.rescan() }
                }
            }
        }
        .animation(reduceMotionDisabled ? nil : .snappy(duration: 0.28), value: store.busyMessage)
    }

    private func tierContent(_ report: ScanReport) -> some View {
        let items = store.tierTab.findings(in: report)
        return VStack(spacing: 0) {
            if items.isEmpty {
                TierEmptyView(tab: store.tierTab) {
                    Task { await store.rescan() }
                }
            } else {
                List {
                    if store.tierTab == .locked {
                        lockedSection(items)
                    } else {
                        deletableSection(items)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            actionBar
        }
    }

    private func deletableSection(_ items: [Finding]) -> some View {
        Section {
            ForEach(items) { finding in
                FindingRow(
                    finding: finding,
                    isSelected: store.selection.contains(finding.id),
                    onToggle: { store.toggle(finding) }
                )
            }
        } header: {
            HStack {
                Text("Will be deleted · \(items.count) item\(items.count == 1 ? "" : "s")")
                Spacer()
                Button("All") { store.selectAll(in: store.tierTab) }
                Button("None") { store.selectNone(in: store.tierTab) }
            }
            .font(.system(size: 10.5))
        }
    }

    private func lockedSection(_ items: [Finding]) -> some View {
        Section {
            ForEach(items) { finding in
                FindingRow(
                    finding: finding,
                    isSelected: false,
                    onToggle: {}
                )
                .disabled(true)
            }
        } header: {
            HStack {
                Text("Locked · never deleted")
                Spacer()
                Text("\(items.count)")
            }
            .font(.system(size: 10.5))
        } footer: {
            Text("These failed cross-verification or sit on the permanent red blocklist. They are excluded from the cleanup total and no delete control is offered.")
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedBytes > 0
                     ? "\(store.selectedFindings.count) selected · \(ByteFormat.string(store.selectedBytes))"
                     : "Nothing selected")
                    .font(.system(size: 12, weight: .medium))
                if store.selectedLockedCount > 0 {
                    Text("\(store.selectedLockedCount) locked item\(store.selectedLockedCount == 1 ? "" : "s") excluded")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Review & Delete…", action: onClean)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!store.canClean)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Opens a list of every path that will be deleted (⌘↩)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .contain)
    }

    private var reduceMotionDisabled: Bool { !reduceMotion }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

struct TierEmptyView: View {
    let tab: TierTab
    let onScan: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: tab.symbolName)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(tab.emptyTitle)
                .font(.system(size: 15, weight: .medium))
            Text(tab.emptyMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Scan now", action: onScan)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct EmptyStateView: View {
    let onScan: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "internaldrive")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing scanned yet")
                .font(.system(size: 15, weight: .medium))
            Text("Dustless measures developer caches without deleting anything.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Scan now", action: onScan)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EngineErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.orange)
            Text("The cleanup engine is unavailable")
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
            Button("Try again", action: onRetry)
                .controlSize(.large)
            Text("Nothing has been deleted.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
