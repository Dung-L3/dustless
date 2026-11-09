import DustlessKit
import SwiftUI
import AppKit

struct MemoryView: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var killResults: [Int: KillStatus] = [:]
    @State private var quitResults: [String: Bool] = [:]
    @State private var pendingStop: PendingStop?
    @State private var stopping: Set<Int> = []
    @State private var quitting: Set<String> = []
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
            .accessibilityIdentifier("memory.stop.cancel")
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

            if let error = store.memoryError, store.memoryReport != nil {
                staleBanner(error)
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

    private func staleBanner(_ error: L10nText) -> some View {
        HStack(alignment: .top, spacing: PanelStyle.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            EngineErrorMessage(
                text: error,
                retry: { Task { await store.fetchMemory() } },
                retryIdentifier: "memory.retry"
            )
            Button(action: { store.dismissMemoryError() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(settings.t("close"))
            .accessibilityLabel(settings.t("close"))
            .accessibilityIdentifier("memory.error.dismiss")
            Spacer(minLength: 0)
        }
        .padding(PanelStyle.Space.s)
        .panelCard(PanelStyle.rowFill)
        .accessibilityIdentifier("memory.error")
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
        let open = isExpanded(group, in: groups)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Button {
                    withAnimation(Motion.gated(reduceMotion, Motion.control)) {
                        setExpanded(!open, for: group)
                    }
                } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textMuted)
                        .frame(width: 18, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(settings.t(open ? "collapseGroup" : "expandGroup"))
                .accessibilityIdentifier("memory.expand.\(group.id)")

                groupHeader(group, isLargest: isLargest, isOpen: open)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)

            if open {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group.processes) { proc in
                        processRow(proc)
                    }
                }
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.Palette.hairline)
                        .frame(width: 1.5)
                }
                .padding(.leading, 42)
                .padding(.trailing, Theme.Space.m)
                .padding(.bottom, Theme.Space.s)
            }
        }
        .background(Theme.Palette.raised, in: .rect(cornerRadius: Theme.Radius.inner))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous)
                .stroke(Theme.Palette.hairline, lineWidth: 1)
        }
    }

    private func groupHeader(_ group: ProcessGroup, isLargest: Bool, isOpen: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            groupIcon(group)

            VStack(alignment: .leading, spacing: 1) {
                Text(group.displayName)
                    .font(Theme.Font.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(group.bundlePath ?? group.label)
                    .accessibilityHint(group.label)
                    .accessibilityIdentifier("memory.group.\(group.id)")
                Text(settings.processCount(group.count))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textMuted)
                    .lineLimit(1)
            }

            if let category = groupCategory(group) {
                StatusChip(
                    color: categoryColor(category),
                    text: settings.t(categoryKey(category))
                )
            }

            Spacer(minLength: Theme.Space.s)

            Text(ByteFormat.string(group.bytes))
                .font(Theme.Font.number(.semibold, size: 13))
                .frame(minWidth: 64, alignment: .trailing)

            if isLargest {
                StatusPill(text: settings.t("memoryLargest"), tone: .warning)
            }

            if let asked = quitResults[group.id] {
                Image(systemName: asked ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(asked ? Theme.Palette.accent : Theme.Palette.danger)
                    .help(settings.t(asked ? "memoryQuitAsked" : "memoryQuitFailed", ["name": group.displayName]))
                    .accessibilityLabel(settings.t(asked ? "memoryQuitAsked" : "memoryQuitFailed", ["name": group.displayName]))
                    .accessibilityIdentifier("memory.quit.status.\(group.id)")
            }

            if AppQuit.target(for: group) != nil {
                Button {
                    askToQuit(group)
                } label: {
                    HStack(spacing: 4) {
                        if quitting.contains(group.id) {
                            ProgressView().controlSize(.mini).scaleEffect(0.55).frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Text(settings.t("memoryQuitApp"))
                    }
                }
                .buttonStyle(.plain)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Theme.Palette.hover, in: .capsule)
                .disabled(quitting.contains(group.id))
                .help(settings.t("memoryQuitHelp", ["name": group.displayName]))
                .accessibilityLabel(settings.t("memoryQuitHelp", ["name": group.displayName]))
                .accessibilityIdentifier("memory.quit.\(group.id)")
            }
        }
        .accessibilityElement(children: .contain)
    }


    private func askToQuit(_ group: ProcessGroup) {
        guard let target = AppQuit.target(for: group) else { return }
        quitting.insert(group.id)
        quitResults[group.id] = AppQuit.requestQuit(target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            Task { await store.fetchMemory() }
            quitting.remove(group.id)
        }
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
            isStopping: stopping.contains(proc.pid),
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
        guard !stopping.contains(pid) else { return }
        stopping.insert(pid)
        Task {
            defer { stopping.remove(pid) }
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
