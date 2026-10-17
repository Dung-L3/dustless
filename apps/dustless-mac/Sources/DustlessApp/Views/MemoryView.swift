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

struct MemoryView: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var killResults: [Int: KillStatus] = [:]
    @State private var isStopping = false
    @State private var hoveredPID: Int?
    @State private var collapsed: Set<String>?
    @State private var query = ""
    @State private var category: MemCategoryFilter = .all

    private static let groupLimit = 15

    var body: some View {
        let report = store.memoryReport
        let matched = filteredGroups(report)
        let groups = Array(matched.prefix(Self.groupLimit))
        PanelScaffold {
            header(report)
        } summary: {
            PanelStatStrip(stats: metricStats(report?.memory))
        } filters: {
            filterBar
        } content: {
            processList(groups, summary: countSummary(groups: groups, matched: matched))
        }
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
        PanelHeader(title: settings.t("memory")) {
            HStack(spacing: PanelStyle.Space.s) {
                if let report {
                    pressureChip(report)
                }
                RefreshButton(isBusy: store.memoryPhase == .loading) {
                    Task { await store.fetchMemory() }
                }
            }
        }
    }

    private var filterBar: some View {
        PanelFilterBar(placeholder: settings.t("searchProcesses"), text: $query) {
            Picker(settings.t("filterCategory"), selection: $category) {
                ForEach(MemCategoryFilter.allCases) { option in
                    Text(option.titleKey.flatMap { settings.t($0) } ?? settings.t("filterAll")).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel(settings.t("filterCategory"))
        } trailing: {
            EmptyView()
        }
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
            }

            if groups.isEmpty {
                Text(isFiltering ? settings.t("noMatches") : settings.t("memoryNoProcesses"))
                    .font(PanelFont.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
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

            Text(group.label)
                .font(PanelFont.emphasis(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(group.bundlePath ?? group.id)

            Spacer(minLength: PanelStyle.Space.s)

            Text(settings.t("memoryProcessCount", ["n": "\(group.count)"]))
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
        HStack(spacing: PanelStyle.Space.s) {
            Text(proc.name)
                .font(PanelFont.mono(12))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(proc.command)
                .accessibilityLabel(rowDescription(proc))

            StatusChip(
                color: categoryColor(proc.category),
                text: settings.t(categoryKey(proc.category))
            )

            Spacer(minLength: 6)

            Text("\(proc.pid)")
                .font(PanelFont.mono(12))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)

            Text(ByteFormat.string(proc.mem))
                .font(PanelFont.number())
                .frame(minWidth: 64, alignment: .trailing)

            stopButton(for: proc)
        }
        .padding(.vertical, 3)
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

    private func rowDescription(_ proc: MemProcess) -> String {
        [
            proc.name,
            settings.t("memoryProcessPID") + " " + "\(proc.pid)",
            settings.t(categoryKey(proc.category)),
            ByteFormat.string(proc.mem),
        ].joined(separator: ", ")
    }

    @ViewBuilder
    private func stopButton(for proc: MemProcess) -> some View {
        if let status = killResults[proc.pid] {
            statusView(status, for: proc)
        } else {
            let hovering = hoveredPID == proc.pid
            Button(action: { killProcess(pid: proc.pid, force: false, sigkill: false) }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(hovering ? Color.red : Color.secondary.opacity(0.8))
                    .frame(width: 24, height: 20)
                    .background(hovering ? Color.red.opacity(0.14) : .clear, in: .rect(cornerRadius: 5))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                hoveredPID = hovering ? proc.pid : (hoveredPID == proc.pid ? nil : hoveredPID)
            }
            .help(settings.t("memoryStopNamed", ["name": proc.name]))
            .accessibilityLabel(settings.t("memoryStopNamed", ["name": proc.name]))
            .contextMenu {
                Button(action: { killProcess(pid: proc.pid, force: true, sigkill: true) }) {
                    Label(
                        settings.t("memoryForceStopNamed", ["name": proc.name]),
                        systemImage: "exclamationmark.octagon.fill"
                    )
                }
            }
            .disabled(isStopping)
        }
    }

    @ViewBuilder
    private func statusView(_ status: KillStatus, for proc: MemProcess) -> some View {
        let tint = status.ok ? Color.green : Color.red
        let label = status.ok
            ? settings.t("memoryStoppedNamed", ["name": proc.name])
            : (status.reason.map { reasonText($0) } ?? settings.t("memoryStopError"))
        Image(systemName: status.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .help(label)
            .accessibilityLabel(label)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale))
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { killResults[status.pid] = nil }
                }
            }
    }

    private func reasonText(_ reason: KillReason) -> String {
        switch reason {
        case .engine(let sentence): sentence
        case .translated(let text): settings.text(text)
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

    private func categoryColor(_ category: MemCategory) -> Color {
        switch category {
        case .browser: return .blue
        case .editor: return .purple
        case .container: return .teal
        case .lsp: return .orange
        case .other: return .secondary
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

private struct KillStatus: Identifiable {
    let id = UUID()
    let pid: Int
    let ok: Bool
    let reason: KillReason?
}

private enum KillReason {
    case engine(String)
    case translated(L10nText)
}