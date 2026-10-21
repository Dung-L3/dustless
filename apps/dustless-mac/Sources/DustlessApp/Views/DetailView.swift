import DustlessKit
import SwiftUI

struct DetailView: View {
    @ObservedObject var store: ScanStore
    let onClean: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var listOpacity = 1.0

    var body: some View {
        VStack(spacing: 0) {
            if let message = store.busyMessage {
                HStack(spacing: PanelStyle.Space.s) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text(settings.text(message))
                        .font(PanelFont.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, PanelStyle.Space.s)
                .background(.ultraThinMaterial)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let report = store.report {
                if let error = store.engineError {
                    staleBanner(settings.text(error))
                        .transition(.opacity)
                }
                tierContent(report)
            } else if let error = store.engineError {
                EngineErrorView(
                    message: settings.text(error),
                    isBusy: store.isBusy
                ) {
                    Task { await store.rescan() }
                }
            } else {
                EmptyStateView(isBusy: store.isBusy) {
                    Task { await store.rescan() }
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: PanelMotion.banner), value: store.busyMessage)
        .animation(PanelMotion.gated(reduceMotion, PanelMotion.fade), value: store.engineError == nil)
    }

    private func staleBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: PanelStyle.Space.s) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(PanelFont.mono(11))
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(2)
                .truncationMode(.tail)
                .help(text)
                .accessibilityLabel(text)
            Button(action: { store.dismissEngineError() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(settings.t("close"))
            .accessibilityLabel(settings.t("close"))
            .accessibilityIdentifier("cleanup.error.dismiss")
        }
        .padding(.horizontal, PanelStyle.Space.l)
        .padding(.vertical, PanelStyle.Space.s)
    }

    private func tierContent(_ report: ScanReport) -> some View {
        let allItems = store.tierTab.findings(in: report)
        let filteredItems = filteredFindings(allItems)
        return VStack(spacing: 0) {
            if let apply = store.lastApply, store.showingCleanupResult {
                CleanupResultCard(report: apply) { store.showingCleanupResult = false }
                    .padding(.horizontal, PanelStyle.Space.l)
                    .padding(.top, PanelStyle.Space.m)
                    .transition(.opacity)
            }

            PanelFilterBar(
                placeholder: settings.t("searchFindings"),
                text: $store.findingsQuery,
                filter: { EmptyView() },
                trailing: { EmptyView() },
                searchIdentifier: "cleanup.search"
            )
            .padding(.horizontal, PanelStyle.Space.l)
            .padding(.vertical, PanelStyle.Space.s)

            if allItems.isEmpty {
                TierEmptyView(tab: store.tierTab, isBusy: store.isBusy) {
                    Task { await store.rescan() }
                }
            } else if filteredItems.isEmpty && !store.findingsQuery.isEmpty {
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
                .opacity(listOpacity)
            }

            Divider()
            actionBar
        }
        .onChange(of: store.scannedAt) { _, _ in
            fadeInFindings()
        }
    }

    private func fadeInFindings() {
        guard !reduceMotion else {
            listOpacity = 1
            return
        }
        listOpacity = 0
        withAnimation(.easeOut(duration: 0.18)) { listOpacity = 1 }
    }

    private func filteredFindings(_ items: [Finding]) -> [Finding] {
        guard !store.findingsQuery.isEmpty else { return items }
        let query = store.findingsQuery.lowercased()
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
                .disabled(store.isBusy)
            }
        } header: {
            HStack {
                Text(settings.t("willDelete"))
                Text(settings.t("itemMany", ["n": "\(items.count)"]))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(settings.t("selectAll")) { store.selectAll(in: store.tierTab) }
                    .disabled(store.isBusy)
                    .accessibilityIdentifier("cleanup.selectAll")
                Button(settings.t("selectNone")) { store.selectNone(in: store.tierTab) }
                    .disabled(store.isBusy)
                    .accessibilityIdentifier("cleanup.selectNone")
            }
            .font(PanelFont.caption)
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
            .font(PanelFont.caption)
            .accessibilityIdentifier("cleanup.locked.header")
        } footer: {
            Text(settings.t("lockedSectionFooter"))
        }
    }

    private var actionBar: some View {
        HStack(spacing: PanelStyle.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedBytes > 0
                     ? settings.t("selectedLine", [
                         "n": "\(store.selectedFindings.count)",
                         "size": ByteFormat.string(store.selectedBytes),
                     ])
                     : settings.t("selectedNone"))
                    .font(PanelFont.emphasis())
                    .accessibilityIdentifier("cleanup.selected")
                if store.selectedLockedCount > 0 {
                    Text(settings.t("lockedExcluded", ["n": "\(store.selectedLockedCount)"]))
                        .font(PanelFont.caption)
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
                .accessibilityIdentifier("cleanup.review")
        }
        .padding(.horizontal, PanelStyle.Space.l)
        .padding(.vertical, PanelStyle.Space.m)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .contain)
    }
}

struct TierEmptyView: View {
    let tab: TierTab
    let isBusy: Bool
    let onScan: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: tab.symbolName)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(settings.tabEmpty(tab))
                .font(PanelFont.emphasis())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(settings.t("rescan"), action: onScan)
                .controlSize(.large)
                .disabled(isBusy)
                .accessibilityIdentifier("cleanup.empty.scan")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cleanup.empty")
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
                .font(PanelFont.emphasis())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cleanup.noMatches")
    }
}

struct EmptyStateView: View {
    let isBusy: Bool
    let onScan: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "internaldrive")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(settings.t("nothingScanned"))
                .font(PanelFont.emphasis(.semibold))
            Text(settings.t("emptyStateBody"))
                .font(PanelFont.body)
                .foregroundStyle(.secondary)
            Button(settings.t("rescan"), action: onScan)
                .controlSize(.large)
                .disabled(isBusy)
                .accessibilityIdentifier("cleanup.emptyState.scan")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EngineErrorView: View {
    let message: String
    let isBusy: Bool
    let onRetry: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.orange)
            Text(settings.t("engineUnavailable"))
                .font(PanelFont.emphasis(.semibold))
            errorMessage
            Button(settings.t("retry"), action: onRetry)
                .controlSize(.large)
                .disabled(isBusy)
                .accessibilityIdentifier("cleanup.retry")
            Text(settings.t("nothingDeleted"))
                .font(PanelFont.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorMessage: some View {
        ScrollView {
            Text(message)
                .font(PanelFont.mono(11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
                .help(message)
        }
        .frame(maxWidth: 520, maxHeight: 220)
    }
}