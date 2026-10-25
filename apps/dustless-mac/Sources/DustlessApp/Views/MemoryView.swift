import DustlessKit
import SwiftUI
import AppKit

typealias MemProcess = DustlessKit.ProcessInfo
typealias MemCategory = DustlessKit.Category

enum MemCategoryFilter: String, CaseIterable, Identifiable {
    case all
    case browser
    case editor
    case container
    case lsp
    case other

    var id: String { rawValue }

    var titleKey: String? {
        switch self {
        case .all: nil
        case .browser: "categoryBrowser"
        case .editor: "categoryEditor"
        case .container: "categoryContainer"
        case .lsp: "categoryLSP"
        case .other: "categoryOther"
        }
    }

    var category: MemCategory? {
        switch self {
        case .all: nil
        case .browser: .browser
        case .editor: .editor
        case .container: .container
        case .lsp: .lsp
        case .other: .other
        }
    }
}

struct PendingStop {
    let pid: Int
    let name: String
    let force: Bool
    let sigkill: Bool
}

struct MemoryView: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var killResults: [Int: KillStatus] = [:]
    @State private var quitResults: [String: Bool] = [:]
    @State private var pendingStop: PendingStop?
    @State private var isStopping = false
    @State private var collapsed: Set<String>?
    @State private var query = ""
    @State private var category: MemCategoryFilter = .all

    private static let groupLimit = 15

    var body: some View {
        let report = store.memoryReport
        let matched = filteredGroups(report)
        let groups = isFiltering ? matched : Array(matched.prefix(Self.groupLimit))
        PanelScaffold {
            header(report)
        } summary: {
            PanelStatStrip(stats: metricStats(report?.memory))
        } filters: {
            filterBar
        } content: {
            processList(groups, summary: countSummary(groups: groups, matched: matched))
        }
        .confirmationDialog(
            stopTitle,
            isPresented: Binding(
                get: { pendingStop != nil },
                set: { if !$0 { pendingStop = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(stopActionLabel, role: .destructive) {
                guard let pending = pendingStop else { return }
                pendingStop = nil
                killProcess(pid: pending.pid, force: pending.force, sigkill: pending.sigkill)
            }
            .accessibilityIdentifier("memory.stop.confirm")
            Button(settings.t("confirmCancel"), role: .cancel) {
                pendingStop = nil
            }
        } message: {
            Text(stopMessage)
        }
    }

    private var stopTitle: String {
        guard let pending = pendingStop else { return "" }
        return settings.t(pending.sigkill ? "memoryForceStopTitle" : "memoryStopConfirmTitle")
    }

    private var stopActionLabel: String {
        guard let pending = pendingStop else { return "" }
        return settings.t(pending.sigkill ? "memoryForceStopAction" : "memoryStopConfirmAction")
    }

    private var stopMessage: String {
        guard let pending = pendingStop else { return "" }
        return settings.t(
            pending.sigkill ? "memoryForceStopBody" : "memoryStopConfirmBody",
            ["name": pending.name, "pid": "\(pending.pid)"]
        )
    }

    private func countSummary(groups: [ProcessGroup], matched: [ProcessGroup]) -> String? {
        let all = store.memoryReport?.processes ?? []
        let shown = groups.reduce(0) { $0 + $1.count }
        let matchedCount = matched.reduce(0) { $0 + $1.count }

        if isFiltering {
            return matched.count > groups.count
                ? settings.t("memoryShowingTop", ["shown": "\(shown)", "total": "\(matchedCount)"])
                : settings.t("filterShowing", ["shown": "\(shown)", "total": "\(all.count)"])
        }
        return shown < all.count
            ? settings.t("memoryShowingTop", ["shown": "\(shown)", "total": "\(all.count)"])
            : nil
    }

    private func header(_ report: MemoryReport?) -> some View {
        PanelHeader(title: settings.t("memory"), identifier: "memory.header") {
            HStack(spacing: PanelStyle.Space.s) {
                if let report {
                    pressureChip(report)
                        .accessibilityIdentifier("memory.pressure")
                }
                RefreshButton(
                    isBusy: store.memoryPhase == .loading,
                    action: { Task { await store.fetchMemory() } },
                    identifier: "memory.refresh"
                )
            }
        }
    }

    private var filterBar: some View {
        PanelFilterBar(
            placeholder: settings.t("searchProcesses"),
            text: $query,
            filter: {
                Picker(settings.t("filterCategory"), selection: $category) {
                    ForEach(MemCategoryFilter.allCases) { option in
                        Text(option.titleKey.flatMap { settings.t($0) } ?? settings.t("filterAll"))
                            .tag(option)
                            .accessibilityIdentifier("memory.filter.\(option.rawValue)")
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            },
            trailing: { EmptyView() },
            searchIdentifier: "memory.search"
        )
    }

    private func pressureChip(_ report: MemoryReport) -> some View {
        let memory = report.memory
        let (labelKey, color): (String, Color) = {
            switch memory.pressure {
            case .normal: return ("pressureNormal", .green)
            case .warn: return ("pressureWarn", .orange)
            case .critical: return ("pressureCritical", .red)
            }
        }()

        return StatusChip(
            color: color,
            text: "\(settings.t("memoryPressure")): \(settings.t(labelKey)) (\(memory.pressurePercent)%)",
            prominent: true
        )
        .help(settings.t("memoryPressureHelp"))
    }

    private func metricStats(_ mem: MemoryInfo?) -> [(label: String, value: String)] {
        func value(_ bytes: UInt64?) -> String { bytes.map(ByteFormat.string) ?? "—" }
        return [
            (settings.t("memoryAvailable"), value(mem?.available)),
            (settings.t("memoryUsed"), value(mem?.used)),
            (settings.t("memoryTotal"), value(mem?.total)),
            (settings.t("memoryCompressed"), value(mem?.compressed)),
            (settings.t("memorySwapUsed"), value(mem?.swapUsed)),
            (settings.t("memorySwapTotal"), value(mem?.swapTotal)),
        ]
    }

    private func processList(_ groups: [ProcessGroup], summary: String?) -> some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            if let summary {
                Text(summary)
                    .font(PanelFont.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(summary)
                    .accessibilityLabel(summary)
                    .accessibilityIdentifier("memory.summary")
            }

            if groups.isEmpty {
                if let error = store.memoryError {
                    PanelStateView(
                        kind: .error,
                        message: settings.text(error),
                        error: error,
                        title: settings.t("engineUnavailable"),
                        actionTitle: settings.t("retry"),
                        action: { Task { await store.fetchMemory() } },
                        identifier: "memory.state",
                        actionIdentifier: "memory.retry"
                    )
                } else {
                    PanelStateView(
                        kind: .empty,
                        message: isFiltering ? settings.t("noMatches") : settings.t("memoryNoProcesses"),
                        identifier: "memory.empty"
                    )
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: PanelStyle.Space.s) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            groupRow(group, isLargest: index == 0, in: groups)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func processGroups(_ report: MemoryReport?) -> [ProcessGroup] {
        (report?.processes ?? []).groupedByApp()
    }

    private var needle: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isFiltering: Bool {
        !needle.isEmpty || category != .all
    }

    private func filteredGroups(_ report: MemoryReport?) -> [ProcessGroup] {
        let needle = needle
        let wanted = category.category
        guard !needle.isEmpty || wanted != nil else { return processGroups(report) }
        return processGroups(report).filter { group in
            if let wanted, !group.contains(category: wanted) { return false }
            return group.matches(needle)
        }
    }

    private func groupRow(_ group: ProcessGroup, isLargest: Bool, in groups: [ProcessGroup]) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { isExpanded(group, in: groups) },
            set: { setExpanded($0, for: group) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                if let target = AppQuit.target(for: group) {
                    quitRow(group, target: target)
                }
                ForEach(group.processes) { proc in
                    processRow(proc)
                }
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 1.5)
            }
            .padding(.leading, 18)
        } label: {
            groupHeader(group, isLargest: isLargest, isOpen: isExpanded(group, in: groups))
        }
        .padding(.horizontal, PanelStyle.Space.m)
        .padding(.vertical, PanelStyle.Space.s)
        .panelCard(PanelStyle.rowFill)
    }

    private func groupHeader(_ group: ProcessGroup, isLargest: Bool, isOpen: Bool) -> some View {
        HStack(spacing: PanelStyle.Space.s) {
            groupIcon(group)

            Text(group.displayName)
                .font(PanelFont.emphasis(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(group.bundlePath ?? group.label)
                .accessibilityHint(group.label)

            if let category = groupCategory(group) {
                StatusChip(
                    color: categoryColor(category),
                    text: settings.t(categoryKey(category))
                )
            }

            Spacer(minLength: PanelStyle.Space.s)

            Text(settings.processCount(group.count))
                .font(PanelFont.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(ByteFormat.string(group.bytes))
                .font(PanelFont.number(.semibold))
                .frame(minWidth: 64, alignment: .trailing)

            if isLargest {
                StatusChip(color: .orange, text: settings.t("memoryLargest"), prominent: true)
            }
        }
        .help(settings.t(isOpen ? "collapseGroup" : "expandGroup"))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memory.group.\(group.id)")
    }

    private func quitRow(_ group: ProcessGroup, target: AppQuit.Target) -> some View {
        HStack(spacing: PanelStyle.Space.s) {
            if let ok = quitResults[group.id] {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ok ? .green : .red)
                Text(settings.t(ok ? "memoryQuitAsked" : "memoryQuitFailed", ["name": target.name]))
                    .font(PanelFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Button {
                    askToQuit(group, target: target)
                } label: {
                    Label(settings.t("memoryQuitApp"), systemImage: "rectangle.portrait.and.arrow.right")
                        .font(PanelFont.caption)
                }
                .controlSize(.small)
                .help(settings.t("memoryQuitHelp", ["name": target.name]))
                .accessibilityLabel(settings.t("memoryQuitHelp", ["name": target.name]))
                .accessibilityIdentifier("memory.quit.\(group.id)")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func askToQuit(_ group: ProcessGroup, target: AppQuit.Target) {
        let ok = AppQuit.requestQuit(target)
        quitResults[group.id] = ok
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            quitResults[group.id] = nil
        }
    }

    private func groupCategory(_ group: ProcessGroup) -> MemCategory? {
        let categories = Set(group.processes.map(\.category))
        guard categories.count == 1, let category = categories.first else { return nil }
        return category == .other ? nil : category
    }

    @ViewBuilder
    private func groupIcon(_ group: ProcessGroup) -> some View {
        if let path = group.bundlePath {
            Image(nsImage: Self.icon(for: path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }

    @MainActor
    private static var iconCache: [String: NSImage] = [:]

    private static func icon(for path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        if iconCache.count > 400 { iconCache.removeAll(keepingCapacity: true) }
        let image = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = image
        return image
    }

    private func processRow(_ proc: MemProcess) -> some View {
        MemoryProcessRow(
            proc: proc,
            status: killResults[proc.pid],
            isStopping: isStopping,
            onStop: { target in
                pendingStop = PendingStop(pid: target.pid, name: target.name, force: false, sigkill: false)
            },
            onForceStop: { target in
                pendingStop = PendingStop(pid: target.pid, name: target.name, force: true, sigkill: true)
            },
            onStatusCleared: { pid in
                killResults[pid] = nil
            }
        )
    }

    private func isExpanded(_ group: ProcessGroup, in groups: [ProcessGroup]) -> Bool {
        guard let collapsed else { return group.id == groups.first?.id }
        return !collapsed.contains(group.id)
    }

    private func setExpanded(_ expanded: Bool, for group: ProcessGroup) {
        var current = collapsed ?? Set(processGroups(store.memoryReport).dropFirst().map(\.id))
        if expanded { current.remove(group.id) } else { current.insert(group.id) }
        collapsed = current
    }

    private func categoryColor(_ category: MemCategory) -> Color {
        switch category {
        case .browser: return .blue
        case .editor: return .purple
        case .container: return .teal
        case .lsp: return .orange
        case .other: return .secondary
        }
    }

    private func categoryKey(_ category: MemCategory) -> String {
        switch category {
        case .browser: return "categoryBrowser"
        case .editor: return "categoryEditor"
        case .container: return "categoryContainer"
        case .lsp: return "categoryLSP"
        case .other: return "categoryOther"
        }
    }

    private func killProcess(pid: Int, force: Bool, sigkill: Bool) {
        guard !isStopping else { return }
        isStopping = true
        Task {
            defer { isStopping = false }
            do {
                let cli = try DustlessCLI.resolve()
                let result = try await cli.kill(pid: pid, force: force, sigkill: sigkill)
                await MainActor.run {
                    killResults[pid] = KillStatus(pid: pid, ok: result.ok, reason: result.reason.map(KillReason.engine))
                }
                if result.ok {
                    await store.fetchMemory()
                }
            } catch {
                let reason = ScanStore.describe(error)
                await MainActor.run {
                    killResults[pid] = KillStatus(pid: pid, ok: false, reason: .translated(reason))
                }
            }
        }
    }
}
