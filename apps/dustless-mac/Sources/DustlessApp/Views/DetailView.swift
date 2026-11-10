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
                busyBanner(message)
            }

            ScanPermissionNotice(store: store)
                .padding(.horizontal, Theme.Space.page)
                .padding(.top, Theme.Space.s)

            if let report = store.report {
                if let error = store.engineError {
                    staleBanner(error)
                }
                UnscannableNotice(report: report, showsDetail: true, identifier: "cleanup.unscannable")
                    .padding(.horizontal, Theme.Space.page)
                    .padding(.top, Theme.Space.s)
                tierContent(report)
            } else if let error = store.engineError {
                EngineErrorView(message: error, isBusy: store.isBusy) {
                    Task { await store.rescan() }
                }
            } else {
                EmptyStateView(isBusy: store.isBusy, scanLabel: scanLabel) {
                    Task { await store.rescan() }
                }
            }
        }
        .animation(reduceMotion ? nil : Motion.fade, value: store.busyMessage)
        .animation(Motion.gated(reduceMotion, Motion.fade), value: store.engineError == nil)
        .frame(maxHeight: .infinity)
    }

    private var scanLabel: String {
        store.report == nil ? settings.t("scanNow") : settings.t("rescan")
    }

    private func busyBanner(_ message: L10nText) -> some View {
        HStack(spacing: Theme.Space.s) {
            ProgressView().controlSize(.small).scaleEffect(0.7)
            Text(settings.text(message))
                .font(Theme.Font.small)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(Theme.Palette.surface)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func staleBanner(_ error: L10nText) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.warning)
            EngineErrorMessage(
                text: error,
                retry: { Task { await store.rescan() } },
                retryIdentifier: "cleanup.retry"
            )
            Button(action: { store.dismissEngineError() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Palette.textMuted)
            .help(settings.t("close"))
            .accessibilityLabel(settings.t("close"))
            .accessibilityIdentifier("cleanup.error.dismiss")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.Palette.warningFill)
    }

    private func tierContent(_ report: ScanReport) -> some View {
        let allItems = store.tierTab.findings(in: report)
        let filteredItems = filteredFindings(allItems)

        return VStack(spacing: 0) {
            HStack {
                TierPillBar(store: store)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.top, Theme.Space.s)

            if let apply = store.lastApply, store.showingCleanupResult {
                CleanupResultCard(report: apply) { store.showingCleanupResult = false }
                    .padding(.horizontal, Theme.Space.page)
                    .padding(.top, Theme.Space.m)
                    .transition(.opacity)
            }

            HStack(spacing: Theme.Space.s) {
                Text(allItems.isEmpty
                     ? settings.tabEmpty(store.tierTab)
                     : sectionCount(shown: filteredItems.count, total: allItems.count))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textMuted)
                Spacer(minLength: Theme.Space.s)
                if store.tierTab != .locked && !allItems.isEmpty {
                    Button(settings.t("selectAll")) { store.selectAll(in: store.tierTab) }
                        .buttonStyle(.plain)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.accent)
                        .disabled(store.isBusy)
                        .accessibilityIdentifier("cleanup.selectAll")
                    Button(settings.t("selectNone")) { store.selectNone(in: store.tierTab) }
                        .buttonStyle(.plain)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textMuted)
                        .disabled(store.isBusy)
                        .accessibilityIdentifier("cleanup.selectNone")
                }
                SearchField(
                    placeholder: settings.t("searchFindings"),
                    text: $store.findingsQuery,
                    identifier: "cleanup.search"
                )
                .frame(maxWidth: 250)
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.vertical, Theme.Space.s)

            listBody(filtered: filteredItems, all: allItems)
                .opacity(listOpacity)

            Divider().overlay(Theme.Palette.hairline)
            actionBar
        }
        .onChange(of: store.scannedAt) { _, _ in
            fadeInFindings()
        }
    }

    @ViewBuilder
    private func listBody(filtered: [Finding], all: [Finding]) -> some View {
        if all.isEmpty {
            TierEmptyView(tab: store.tierTab, isBusy: store.isBusy, scanLabel: scanLabel) {
                Task { await store.rescan() }
            }
        } else if filtered.isEmpty && !store.findingsQuery.isEmpty {
            NoMatchesView()
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    if store.tierTab == .locked {
                        lockedHeader(count: filtered.count)
                    }
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, finding in
                        FindingRow(
                            finding: finding,
                            isSelected: store.selection.contains(finding.id),
                            onToggle: { store.toggle(finding) }
                        )
                        .disabled(store.isBusy)
                        .staggeredAppear(index)
                    }
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.vertical, Theme.Space.s)
            }
            .scrollIndicators(.automatic)
        }
    }

    private func lockedHeader(count: Int) -> some View {
        HStack {
            Text(settings.t("lockedNeverDeleted"))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textMuted)
            Spacer()
            Text("\(count)")
                .font(Theme.Font.number(size: 11))
                .foregroundStyle(Theme.Palette.textMuted)
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("cleanup.locked.header")
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
            finding.path.lowercased().contains(query) ||
            RuleText.description(of: finding, lang: settings.language).lowercased().contains(query)
        }
    }

    private func sectionCount(shown: Int, total: Int) -> String {
        guard shown != total else { return settings.itemCount(total) }
        return settings.t("filterShowing", ["shown": "\(shown)", "total": "\(total)"])
    }

    private var actionBar: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedBytes > 0
                     ? settings.t("selectedLine", [
                         "count": settings.itemCount(store.selectedFindings.count),
                         "size": ByteFormat.string(store.selectedBytes),
                     ])
                     : settings.t("selectedNone"))
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .accessibilityIdentifier("cleanup.selected")
                if store.selectedBytes > 0 {
                    Text(settings.t("willDelete"))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textMuted)
                }
                if store.selectedLockedCount > 0 {
                    Text(settings.t("lockedExcluded", ["count": settings.lockedCount(store.selectedLockedCount)]))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textMuted)
                }
                if let change = store.selectionChange {
                    Text(settings.t("selectionChanged", [
                        "before": settings.itemCount(change.before),
                        "kept": settings.itemCount(change.kept),
                    ]))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cleanup.selectionChange")
                }
            }
            Spacer(minLength: Theme.Space.s)
            Button(settings.t("reviewAndDelete"), action: onClean)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!store.canClean)
                .keyboardShortcut(.return, modifiers: .command)
                .help(settings.t("reviewAndDeleteHelp"))
                .accessibilityHint(settings.t("safetyReadOnly"))
                .accessibilityIdentifier("cleanup.review")
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, Theme.Space.m)
        .background(Theme.Palette.surface)
    }
}

struct TierEmptyView: View {
    let tab: TierTab
    let isBusy: Bool
    let scanLabel: String
    let onScan: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: tab.symbolName)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.Palette.textMuted)
            Text(settings.tabEmpty(tab))
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(scanLabel, action: onScan)
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isBusy)
                .accessibilityIdentifier("cleanup.empty.scan")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cleanup.empty")
    }
}

struct NoMatchesView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.Palette.textMuted)
            Text(settings.t("noMatches"))
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
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
    let scanLabel: String
    let onScan: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "internaldrive")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.Palette.textMuted)
            Text(settings.t("nothingScanned"))
                .font(Theme.Font.section)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(settings.t("emptyStateBody"))
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            Button(scanLabel, action: onScan)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isBusy)
                .accessibilityIdentifier("cleanup.emptyState.scan")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

struct EngineErrorView: View {
    let message: L10nText
    let isBusy: Bool
    let onRetry: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color(nsColor: .systemOrange))
            Text(settings.t("engineUnavailable"))
                .font(Theme.Font.section)
                .foregroundStyle(Theme.Palette.textPrimary)
            errorMessage
            Button(settings.t("retry"), action: onRetry)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isBusy)
                .accessibilityIdentifier("cleanup.retry")
            Text(settings.t("nothingDeleted"))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textMuted)
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorMessage: some View {
        ScrollView {
            EngineErrorMessage(text: message)
                .frame(maxWidth: 520, alignment: .leading)
        }
        .frame(maxWidth: 520, maxHeight: 220)
    }
}
