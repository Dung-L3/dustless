import DustlessKit
import SwiftUI

struct DetailView: View {
    @ObservedObject var store: ScanStore
    let onClean: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Findings-list opacity, animated once per new scan report and nothing else.
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

            // A rescan that failed keeps the report it could not replace, so the
            // error is a banner over the numbers rather than a pane that took
            // them away. Without a report there is nothing to keep, and the
            // error owns the pane — with the retry under it.
            if let report = store.report {
                if let error = store.engineError {
                    staleBanner(settings.text(error))
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
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: store.busyMessage)
    }

    /// The engine's sentence, verbatim, with the × that puts it away. Same
    /// affordance as the result cards: a banner nobody can clear is a permanent
    /// one.
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
        }
        .padding(.horizontal, PanelStyle.Space.l)
        .padding(.vertical, PanelStyle.Space.s)
    }

    private func tierContent(_ report: ScanReport) -> some View {
        let allItems = store.tierTab.findings(in: report)
        let filteredItems = filteredFindings(allItems)
        return VStack(spacing: 0) {
            // What the last clean did, above the list it changed rather than
            // over it: after the deletion the user should still be able to read
            // what is left. Stays on screen through the post-clean rescan, which
            // is what leaves the fresh list visible under it.
            if let apply = store.lastApply, store.showingCleanupResult {
                CleanupResultCard(report: apply) { store.showingCleanupResult = false }
                    .padding(.horizontal, PanelStyle.Space.l)
                    .padding(.top, PanelStyle.Space.m)
            }

            // The same in-panel filter field every other module uses, rather
            // than `.searchable`: that attaches to the window toolbar, so the
            // field appeared beside the sidebar and a query was lost on every
            // module switch. The query lives in the store, which outlives both.
            PanelFilterBar(placeholder: settings.t("searchFindings"), text: $store.findingsQuery) {
                EmptyView()
            } trailing: {
                EmptyView()
            }
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
                // A new report replaced the findings under the cursor, so a short
                // fade says "these are new numbers" without moving anything —
                // a slide would imply the rows scrolled away on their own.
                .opacity(listOpacity)
            }

            Divider()
            actionBar
        }
        .onChange(of: store.scannedAt) { _, _ in
            fadeInFindings()
        }
    }

    /// Opacity only, and under 200ms: enough for a changed list to register as
    /// changed, short enough that a ⌘R does not feel like a page turn. Nothing
    /// happens at all when the user asked for less motion.
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
                // Held for the whole run: the list under these rows is about to
                // be replaced by a new report with its own selection, so a
                // toggle made during the scan is a decision about a list that is
                // no longer on screen.
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
                Button(settings.t("selectNone")) { store.selectNone(in: store.tierTab) }
                    .disabled(store.isBusy)
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
                .font(PanelFont.emphasis())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
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
            Text(message)
                .font(PanelFont.mono(11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
            Button(settings.t("retry"), action: onRetry)
                .controlSize(.large)
                .disabled(isBusy)
            Text(settings.t("nothingDeleted"))
                .font(PanelFont.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
