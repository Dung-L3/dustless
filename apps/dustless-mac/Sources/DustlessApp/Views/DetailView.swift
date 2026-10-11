import DustlessKit
import SwiftUI

struct DetailView: View {
    @ObservedObject var store: ScanStore
    let onClean: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            if let message = store.busyMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text(settings.text(message))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let error = store.engineError {
                EngineErrorView(message: settings.text(error)) { Task { await store.rescan() } }
            } else if let report = store.report {
                tierContent(report)
            } else {
                EmptyStateView {
                    Task { await store.rescan() }
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: store.busyMessage)
    }

    private func tierContent(_ report: ScanReport) -> some View {
        let allItems = store.tierTab.findings(in: report)
        let filteredItems = filteredFindings(allItems)
        return VStack(spacing: 0) {
            if allItems.isEmpty {
                TierEmptyView(tab: store.tierTab) {
                    Task { await store.rescan() }
                }
            } else if filteredItems.isEmpty && !searchQuery.isEmpty {
                NoMatchesView()
            } else {
                List {
                    if store.tierTab == .locked {
                        lockedSection(filteredItems)
                    } else {
                        deletableSection(filteredItems)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            actionBar
        }
        .searchable(text: $searchQuery, prompt: settings.t("searchFindings"))
    }

    private func filteredFindings(_ items: [Finding]) -> [Finding] {
        guard !searchQuery.isEmpty else { return items }
        let query = searchQuery.lowercased()
        return items.filter { finding in
            finding.ruleId.lowercased().contains(query) ||
            finding.path.lowercased().contains(query)
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
                Text(settings.t("willDelete"))
                Text(settings.t("itemMany", ["n": "\(items.count)"]))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(settings.t("selectAll")) { store.selectAll(in: store.tierTab) }
                Button(settings.t("selectNone")) { store.selectNone(in: store.tierTab) }
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
                Text(settings.t("lockedNeverDeleted"))
                Spacer()
                Text("\(items.count)")
            }
            .font(.system(size: 10.5))
        } footer: {
            Text(settings.t("lockedSectionFooter"))
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedBytes > 0
                     ? settings.t("selectedLine", [
                         "n": "\(store.selectedFindings.count)",
                         "size": ByteFormat.string(store.selectedBytes),
                     ])
                     : settings.t("selectedNone"))
                    .font(.system(size: 12, weight: .medium))
                if store.selectedLockedCount > 0 {
                    Text(settings.t("lockedExcluded", ["n": "\(store.selectedLockedCount)"]))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(settings.t("reviewAndDelete"), action: onClean)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!store.canClean)
                .keyboardShortcut(.return, modifiers: .command)
                .help(settings.t("reviewAndDeleteHelp"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .contain)
    }
}

struct TierEmptyView: View {
    let tab: TierTab
    let onScan: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: tab.symbolName)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(settings.tabEmpty(tab))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(settings.t("rescan"), action: onScan)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct NoMatchesView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(settings.t("noMatches"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct EmptyStateView: View {
    let onScan: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "internaldrive")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(settings.t("nothingScanned"))
                .font(.system(size: 15, weight: .medium))
            Text(settings.t("emptyStateBody"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button(settings.t("rescan"), action: onScan)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EngineErrorView: View {
    let message: String
    let onRetry: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.orange)
            Text(settings.t("engineUnavailable"))
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
            Button(settings.t("retry"), action: onRetry)
                .controlSize(.large)
            Text(settings.t("nothingDeleted"))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
