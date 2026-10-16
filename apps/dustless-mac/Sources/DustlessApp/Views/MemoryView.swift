import DustlessKit
import SwiftUI
import AppKit

/// Avoid collision with Foundation.NSProcessInfo
typealias MemProcess = DustlessKit.ProcessInfo
typealias MemCategory = DustlessKit.Category

/// The category a process can be narrowed to. `all` is the unfiltered default,
/// so the picker never removes rows on its own.
enum MemCategoryFilter: String, CaseIterable, Identifiable {
    case all
    case browser
    case editor
    case container
    case lsp
    case other

    var id: String { rawValue }

    /// Reuses the vocabulary the chips already speak, so the picker and the rows
    /// never disagree about what a "Browser" is.
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

    @State private var killResults: [Int: KillStatus] = [:]
    /// A kill is in flight; stop buttons are held until the engine answers.
    @State private var isStopping = false
    /// Which row the pointer is over, so the stop button only lights up there.
    @State private var hoveredPID: Int?
    /// The groups the user folded away. `nil` until the first click, which is how
    /// the biggest group starts open: a hog should not need a second click to see.
    @State private var collapsed: Set<String>?
    /// Name / bundle / process / pid search over the groups.
    @State private var query = ""
    /// The category the list is narrowed to, or `.all`.
    @State private var category: MemCategoryFilter = .all

    /// The list is a summary, not a full `ps`. The footer says so. The limit is
    /// on apps, not processes, so a group is never shown with half its memory
    /// missing.
    private static let groupLimit = 15

    var body: some View {
        let report = store.memoryReport
        // Grouped and filtered once here and threaded down: the body re-runs on
        // every hover and every keystroke, and regrouping per row would be wasted
        // work. `matched` is the uncapped result, so the header can say how many
        // the filter found rather than only how many fit under the cap.
        let matched = filteredGroups(report)
        let groups = Array(matched.prefix(Self.groupLimit))
        VStack(alignment: .leading, spacing: 16) {
            header(report)
            Divider()
            metrics(report?.memory)
            Divider()
            processes(report, groups, matched: matched)
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 700, minHeight: 560, idealHeight: 660)
        .background(.regularMaterial)
    }

    private func header(_ report: MemoryReport?) -> some View {
        PanelHeader(title: settings.t("memory")) {
            HStack(spacing: 8) {
                if let report {
                    pressureChip(report)
                }
                RefreshButton(isBusy: store.memoryPhase == .loading) {
                    Task { await store.fetchMemory() }
                }
            }
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

    /// Six tiles directly on the window background — no wrapping card, so the
    /// tiles read as one group instead of as cards inside a card.
    private func metrics(_ mem: MemoryInfo?) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(metricTiles(mem), id: \.label) { tile in
                MetricCard(label: tile.label, value: tile.value)
                    .padding(10)
                    .panelCard()
            }
        }
    }

    private func metricTiles(_ mem: MemoryInfo?) -> [(label: String, value: String)] {
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

    /// One row per application, biggest first, each one opening onto the
    /// processes it owns — twelve helpers eating 4 GB should read as one hog,
    /// not as twelve rows competing for the same attention.
    private func processes(_ report: MemoryReport?, _ groups: [ProcessGroup], matched: [ProcessGroup]) -> some View {
        let all = report?.processes ?? []
        let shown = groups.reduce(0) { $0 + $1.count }
        let matchedCount = matched.reduce(0) { $0 + $1.count }
        let capped = matched.count > groups.count
        let filtered = isFiltering

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(settings.t("memoryProcesses"))
                    .panelSectionHeader()
                if filtered {
                    // Never let the count silently mean "3 of 340" — and when the
                    // filter matched more than the cap draws, say that instead of
                    // pretending the cap is the whole answer.
                    Text(capped
                        ? settings.t("memoryShowingTop", ["shown": "\(shown)", "total": "\(matchedCount)"])
                        : settings.t("filterShowing", ["shown": "\(shown)", "total": "\(all.count)"]))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else if shown < all.count {
                    Text(settings.t("memoryShowingTop", [
                        "shown": "\(shown)",
                        "total": "\(all.count)",
                    ]))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }

            SearchField(placeholder: settings.t("searchProcesses"), text: $query)
                .frame(maxWidth: 320)

            Picker(settings.t("filterCategory"), selection: $category) {
                ForEach(MemCategoryFilter.allCases) { option in
                    Text(option.titleKey.flatMap { settings.t($0) } ?? settings.t("filterAll")).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel(settings.t("filterCategory"))

            if groups.isEmpty {
                Text(filtered ? settings.t("noMatches") : settings.t("memoryNoProcesses"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                // The list takes whatever height the window has left, so opening a
                // group never grows the window and many groups just scroll.
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            groupRow(group, isLargest: index == 0, in: groups)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// The report's processes as app groups, biggest first. The full list, not a
    /// capped one — the cap is applied after filtering so a category filter
    /// surfaces the biggest members of that category instead of nothing.
    private func processGroups(_ report: MemoryReport?) -> [ProcessGroup] {
        (report?.processes ?? []).groupedByApp()
    }

    // MARK: - Filtering

    /// Trimming first: a box holding only a space is not a search.
    private var needle: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isFiltering: Bool {
        !needle.isEmpty || category != .all
    }

    /// The groups that answer the search and the category filter, uncapped. The
    /// caller applies the cap so it can still report how many matched.
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
            // A rail rather than a card per process: the group already is a card.
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 1.5)
            }
            .padding(.leading, 18)
        } label: {
            groupHeader(group, isLargest: isLargest, isOpen: isExpanded(group, in: groups))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .panelCard(PanelStyle.rowFill)
    }

    private func groupHeader(_ group: ProcessGroup, isLargest: Bool, isOpen: Bool) -> some View {
        HStack(spacing: 8) {
            groupIcon(group)

            Text(group.label)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(group.bundlePath ?? group.id)

            Spacer(minLength: 8)

            Text(settings.t("memoryProcessCount", ["n": "\(group.count)"]))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(ByteFormat.string(group.bytes))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(minWidth: 64, alignment: .trailing)

            if isLargest {
                StatusChip(color: .orange, text: settings.t("memoryLargest"), prominent: true)
            }
        }
        .help(settings.t(isOpen ? "collapseGroup" : "expandGroup"))
        .accessibilityElement(children: .combine)
    }

    /// The real bundle icon when there is a bundle. `NSWorkspace` reads the icon
    /// file off disk on every ask and this runs inside `body` — which re-runs on
    /// every hover change and every keystroke in the filter — so memoise it per
    /// bundle path.
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

    /// Lives for the process: a Mac has a few hundred bundles at most and each
    /// entry is one icon, so an unbounded map is fine until it isn't — past that
    /// it is dropped wholesale rather than kept forever.
    @MainActor
    private static var iconCache: [String: NSImage] = [:]

    private static func icon(for path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        if iconCache.count > 400 { iconCache.removeAll(keepingCapacity: true) }
        let image = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = image
        return image
    }

    /// One process inside its group. The stop button and its force-stop context
    /// menu are the row actions the flat list always had.
    private func processRow(_ proc: MemProcess) -> some View {
        HStack(spacing: 8) {
            Text(proc.name)
                .font(.system(size: 12, design: .monospaced))
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
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)

            Text(ByteFormat.string(proc.mem))
                .font(.system(size: 12.5, weight: .medium, design: .rounded).monospacedDigit())
                .frame(minWidth: 64, alignment: .trailing)

            stopButton(for: proc)
        }
        .padding(.vertical, 3)
    }

    /// Until the first click only the biggest group is open; after that the
    /// user's own choices stand, even when a refresh reorders the list.
    private func isExpanded(_ group: ProcessGroup, in groups: [ProcessGroup]) -> Bool {
        guard let collapsed else { return group.id == groups.first?.id }
        return !collapsed.contains(group.id)
    }

    private func setExpanded(_ expanded: Bool, for group: ProcessGroup) {
        var current = collapsed ?? Set(processGroups(store.memoryReport).dropFirst().map(\.id))
        if expanded { current.remove(group.id) } else { current.insert(group.id) }
        collapsed = current
    }

    /// Spoken once for the whole row rather than as four disconnected cells.
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
            : (status.reason ?? settings.t("memoryStopError"))
        Image(systemName: status.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .help(label)
            .accessibilityLabel(label)
            .transition(.opacity.combined(with: .scale))
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { killResults[status.pid] = nil }
                }
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
        Task {
            isStopping = true
            defer { isStopping = false }
            do {
                let cli = try DustlessCLI.resolve()
                let result = try await cli.kill(pid: pid, force: force, sigkill: sigkill)
                await MainActor.run {
                    killResults[pid] = KillStatus(pid: pid, ok: result.ok, reason: result.reason)
                }
                if result.ok {
                    await store.fetchMemory()
                }
            } catch {
                await MainActor.run {
                    killResults[pid] = KillStatus(pid: pid, ok: false, reason: error.localizedDescription)
                }
            }
        }
    }
}

private struct KillStatus: Identifiable {
    let id = UUID()
    let pid: Int
    let ok: Bool
    let reason: String?
}