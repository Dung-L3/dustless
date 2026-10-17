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
    /// The kill status pops in with a scale. With Reduce Motion on, the fade
    /// stays — it is the signal that the row changed — and only the growth is
    /// dropped, because a scaling element is exactly what that setting is about.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    /// The cap and the filter are the two things a reader of this list can get
    /// wrong, so the count is never silent — and when the filter matched more
    /// than the cap draws, it says that instead of pretending the cap is the
    /// whole answer. Nothing to say means nothing is drawn.
    ///
    /// It stays a caption above the list rather than a chip in the filter row: the
    /// six-segment category picker leaves no room there for a sentence, and a
    /// truncated "Showing the top…" is worse than no count at all.
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

    /// Category on the left, search on the right: one row. It was a search row and
    /// then a separate category row, which is two bands of chrome for one
    /// decision and left the list with the leftovers.
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

    /// Six numbers in a strip rather than six tiles in a 3×2 grid: the grid cost
    /// about 100pt of window before the first process row and said nothing the
    /// strip does not.
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

    /// One row per application, biggest first, each one opening onto the
    /// processes it owns — twelve helpers eating 4 GB should read as one hog,
    /// not as twelve rows competing for the same attention.
    private func processList(_ groups: [ProcessGroup], summary: String?) -> some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            if let summary {
                // Pinned above the list, so it is capped like every other band
                // here: the list is the one flexible child in this column and an
                // uncapped sentence takes its height. One line is measured to be
                // enough — the longest of the three languages is 201pt of a
                // 608pt pane — so this caps the *band*, not the words, and the
                // sentence below is never truncated in practice.
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
                // The list takes whatever height the window has left, so opening a
                // group never grows the window and many groups just scroll.
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
        // Set on the main actor, HERE, not inside the task body: a second click
        // in the same run loop would otherwise still see `isStopping == false`,
        // so a double-click on the stop button starts two kills of the same pid
        // and the engine answers the second one with "no such process".
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
                // The engine's own English is not the app's wording: the same
                // mapping the other panels use.
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
    /// A key, not rendered text: the engine's `reason` string is kept verbatim
    /// because it explains the refusal in its own words, while a thrown error
    /// arrives here already mapped onto the app's translations.
    let reason: KillReason?
}

/// Either side of a failed kill, resolved at render time.
private enum KillReason {
    case engine(String)
    case translated(L10nText)
}