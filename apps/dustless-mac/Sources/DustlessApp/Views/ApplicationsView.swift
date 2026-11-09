import AppKit
import DustlessKit
import SwiftUI

enum ApplicationsSort: String, CaseIterable, Identifiable {
    case name
    case size

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .name: "sortName"
        case .size: "sortSize"
        }
    }
}

struct ApplicationsModuleView: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ApplicationsView()
            .task { await store.fetchStorageApps() }
    }
}

struct ApplicationsView: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var control = ApplicationsControl()

    @State private var query = ""
    @State private var sort: ApplicationsSort = .size
    @State private var runningOnly = false
    @State private var expanded: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PanelScaffold {
            PanelHeader(
                title: settings.t("appsTitle"),
                subtitle: settings.t("appsSubtitle"),
                identifier: "applications.header"
            ) {
                HStack(spacing: Theme.Space.s) {
                    runningFilter
                    sortMenu
                    RefreshButton(
                        isBusy: store.isLoadingStorageApps,
                        action: { Task { await store.fetchStorageApps() } },
                        identifier: "applications.refresh"
                    )
                }
            }
        } summary: {
            metricStrip
        } filters: {
            PanelFilterBar(
                placeholder: settings.t("searchApps"),
                text: $query,
                filter: { EmptyView() },
                trailing: { EmptyView() },
                searchIdentifier: "applications.search"
            )
        } content: {
            content
        }
        .sheet(item: $control.pendingSheet, onDismiss: { control.cancel() }) { app in
            ApplicationUninstallSheet(
                app: app,
                isRunning: control.isRunning(app),
                isWorking: control.isWorking,
                isQuitting: control.isQuitting
            ) { includeRelated, purge in
                Task { await control.uninstall(app, includeRelated: includeRelated, purge: purge, store: store) }
            } onCancel: {
                control.cancel()
            }
            .environmentObject(settings)
        }
        .alert(
            settings.t("appsUninstall"),
            isPresented: Binding(
                get: { control.error != nil },
                set: { if !$0 { control.dismissError() } }
            )
        ) {
            Button(settings.t("done")) { control.dismissError() }
        } message: {
            Text(control.error.map { settings.text($0) } ?? "")
        }
    }

    private var filtered: [InstalledApp] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = store.storageApps.filter { app in
            (!runningOnly || control.isRunning(app))
                && (needle.isEmpty || app.matches(needle))
        }
        switch sort {
        case .name:
            return base.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            return base.sorted { $0.bytes > $1.bytes }
        }
    }

    private var metricStrip: some View {
        HStack(spacing: Theme.Space.m) {
            MetricTile(
                label: settings.t("appsTitle"),
                value: "\(store.storageApps.count)",
                detail: settings.appCount(store.storageApps.count),
                identifier: "applications.count"
            )
            MetricTile(
                label: settings.t("sortSize"),
                value: ByteFormat.string(store.storageApps.reduce(0) { $0 + $1.bytes }),
                detail: nil,
                identifier: "applications.totalSize"
            )
            MetricTile(
                label: settings.t("relatedData"),
                value: relatedTotal,
                detail: nil,
                identifier: "applications.relatedSize"
            )
            MetricTile(
                label: settings.t("appRunning"),
                value: "\(store.storageApps.filter { control.isRunning($0) }.count)",
                detail: nil,
                identifier: "applications.running"
            )
        }
    }

    private var relatedTotal: String {
        let values = store.storageApps.compactMap(\.relatedBytes)
        guard values.count == store.storageApps.count else { return "—" }
        return ByteFormat.string(values.reduce(0, +))
    }

    private var runningFilter: some View {
        Button {
            runningOnly.toggle()
        } label: {
            StatusPill(
                text: settings.t("appRunning"),
                tone: runningOnly ? .accent : .neutral,
                icon: runningOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
            )
        }
        .buttonStyle(.plain)
        .help(settings.t("appRunning"))
        .accessibilityIdentifier("applications.filter.running")
    }

    private var sortMenu: some View {
        Menu {
            ForEach(ApplicationsSort.allCases) { option in
                Button {
                    sort = option
                } label: {
                    if sort == option {
                        Label(settings.t(option.labelKey), systemImage: "checkmark")
                    } else {
                        Text(settings.t(option.labelKey))
                    }
                }
            }
        } label: {
            Label(settings.t(sort.labelKey), systemImage: "arrow.up.arrow.down")
                .font(Theme.Font.label)
        }
        .menuStyle(.borderlessButton)
        .help(settings.t("sortBy"))
        .accessibilityIdentifier("applications.sort")
    }

    @ViewBuilder
    private var content: some View {
        if let report = control.result {
            StorageResultCard(
                report: report,
                title: settings.t(control.resultIsPartial ? "appsPartialTitle" : "appsUninstalled"),
                onClose: { control.clearResult() }
            )
            .frame(maxHeight: 190)
        }

        if store.isLoadingStorageApps && store.storageApps.isEmpty {
            PanelStateView(
                kind: .loading,
                message: settings.t("busyApps"),
                identifier: "applications.state"
            )
        } else if let error = store.storageAppsError, store.storageApps.isEmpty {
            PanelStateView(
                kind: .error,
                message: settings.text(error),
                error: error,
                title: settings.t("engineUnavailable"),
                actionTitle: settings.t("retry"),
                action: { Task { await store.fetchStorageApps() } },
                identifier: "applications.state",
                actionIdentifier: "applications.retry"
            )
        } else if store.storageApps.isEmpty {
            PanelStateView(
                kind: .empty,
                message: settings.t("appsNone"),
                title: settings.t("appsTitle"),
                identifier: "applications.state"
            )
        } else if filtered.isEmpty {
            PanelStateView(
                kind: .empty,
                message: settings.t("noMatches"),
                title: settings.t("appsTitle"),
                identifier: "applications.state"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, app in
                        ApplicationRow(
                            app: app,
                            isRunning: control.isRunning(app),
                            expanded: expanded.contains(app.id),
                            isWorking: control.workingApp == app.path,
                            onToggle: {
                                withAnimation(Motion.gated(reduceMotion, Motion.control)) {
                                    if expanded.contains(app.id) {
                                        expanded.remove(app.id)
                                    } else {
                                        expanded.insert(app.id)
                                    }
                                }
                            },
                            onUninstall: { control.requestUninstall(app) }
                        )
                        .staggeredAppear(index)
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
    }
}

private struct ApplicationRow: View {
    let app: InstalledApp
    let isRunning: Bool
    let expanded: Bool
    let isWorking: Bool
    let onToggle: () -> Void
    let onUninstall: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Theme.Space.s) {
                        Text(app.name)
                            .font(Theme.Font.label)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("applications.app.\(app.bundleId)")
                        if app.isProtected {
                            StatusPill(text: settings.t("appsProtected"), tone: .danger, icon: "lock.fill")
                        }
                        if isRunning {
                            StatusPill(text: settings.t("appRunning"), tone: .accent)
                        }
                        if !app.relatedItems.isEmpty {
                            StatusPill(
                                text: settings.t("relatedData"),
                                tone: .neutral,
                                icon: "shippingbox"
                            )
                        }
                    }
                    HStack(spacing: 6) {
                        Text(app.bundleId)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textMuted)
                            .lineLimit(1)
                        Text("·")
                            .foregroundStyle(Theme.Palette.textMuted)
                        PathText(path: app.path, font: Theme.Font.caption)
                    }
                }
                Spacer(minLength: Theme.Space.s)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ByteFormat.string(app.bytes))
                        .font(Theme.Font.number(.semibold, size: 13))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    if let related = app.relatedBytes, related > 0 {
                        Text("+ \(ByteFormat.string(related)) \(settings.t("relatedData").lowercased())")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textMuted)
                            .lineLimit(1)
                    }
                }
                Button(action: onToggle) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.textMuted)
                .accessibilityLabel(expanded ? settings.t("collapseGroup") : settings.t("expandGroup"))
                .accessibilityIdentifier("applications.details.\(app.bundleId)")
                Button(action: onUninstall) {
                    HStack(spacing: 5) {
                        if isWorking {
                            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                        }
                        Text(settings.t("appsUninstall"))
                    }
                }
                .buttonStyle(DestructiveButtonStyle())
                .disabled(isWorking || app.isProtected)
                .help(settings.t("appsUninstall"))
                .accessibilityIdentifier("applications.uninstall.\(app.bundleId)")
            }
            .padding(Theme.Space.m)
            .contentShape(.rect)
            .background(hovered ? Theme.Palette.hover : Color.clear, in: .rect(cornerRadius: Theme.Radius.inner))
            .onHover { hovered = $0 }

            if expanded {
                relatedDetails
                    .padding(.leading, 54)
                    .padding(.trailing, Theme.Space.m)
                    .padding(.bottom, Theme.Space.m)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Theme.Palette.raised, in: .rect(cornerRadius: Theme.Radius.inner))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous)
                .stroke(Theme.Palette.hairline, lineWidth: 1)
        }
    }

    private var icon: some View {
        Image(nsImage: ApplicationsIconCache.icon(for: app.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 32, height: 32)
    }

    private var relatedDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            if app.relatedItems.isEmpty {
                Text(settings.t("appsNoRelated"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textMuted)
            } else {
                ForEach(app.relatedItems) { item in
                    HStack(spacing: Theme.Space.s) {
                        Text(settings.t(relatedLabel(item)))
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .frame(width: 112, alignment: .leading)
                        PathText(path: item.path, font: Theme.Font.caption)
                        Spacer(minLength: Theme.Space.s)
                        Text(item.bytes.map(ByteFormat.string) ?? "—")
                            .font(Theme.Font.number(size: 11))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
            }
            Text(settings.t("appsKeepPersonal"))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textMuted)
                .padding(.top, 2)
        }
    }

    private func relatedLabel(_ item: RelatedItem) -> String {
        switch item.kind {
        case "app-support": "relatedSupport"
        case "caches", "webkit", "http-storage": "relatedCache"
        case "preferences", "cookies": "relatedPreferences"
        case "logs": "relatedLogs"
        case "saved-state": "relatedSavedState"
        case "container", "group-container": "relatedContainer"
        default: "relatedOther"
        }
    }
}

enum ApplicationsIconCache {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func icon(for path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        if cache.count > 300 { cache.removeAll(keepingCapacity: true) }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}
