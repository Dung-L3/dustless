import DustlessKit
import SwiftUI
import AppKit

/// What the lower half of the Storage window lists. The volumes above are
/// always visible; this only picks between the two inventories of what is
/// taking the space.
enum StorageSection: String, Identifiable {
    case apps
    case files

    var id: String { rawValue }
}

/// Every dialog this panel shows, as one value.
///
/// They used to be four separate `.sheet(item:)` bindings, and an action that
/// finished a job set its result while clearing its confirmation in the same
/// update — SwiftUI then tried to present one sheet while dismissing another and
/// the window locked up. One binding means there is never a cross-sheet
/// transition: the content swaps in place instead.
///
/// Only the confirmations are here. A result needs no decision, so it is drawn
/// inline by `StorageResultCard` instead of taking over the window.
enum StorageSheet: Identifiable {
    case confirmApp(InstalledApp)
    case confirmFile(LargeFile)

    var id: String {
        switch self {
        case .confirmApp(let app): "app-confirm:\(app.id)"
        case .confirmFile(let file): "file-confirm:\(file.id)"
        }
    }
}

/// The report of the last finished action, plus the wording its title needs.
/// "Uninstalled" reads wrong for a file that was only moved to the Trash, so the
/// key is stored and resolved at render time rather than baking one language into
/// state that outlives a switch.
struct StorageResult: Identifiable {
    let report: UninstallReport
    let titleKey: String

    var id: String { report.id }
}

struct StorageView: View {
    let space: DiskSpace
    let reclaimable: UInt64?
    @EnvironmentObject private var settings: AppSettings

    @State private var volumes: [VolumeInfo] = []
    @State private var section: StorageSection = .apps
    @State private var apps: [InstalledApp] = []
    @State private var isLoadingApps = false
    @State private var appsError: String?
    @State private var appsQuery = ""
    @State private var sheet: StorageSheet?
    /// What the last uninstall or trash removed, drawn inline above the list.
    /// No modal result: the confirmation is the only thing that ever takes the
    /// window over, because it is the only one that asks for a decision.
    @State private var result: StorageResult?
    /// The alert to show once the current sheet is fully gone. An alert cannot
    /// present on top of a sheet, so an error waits for the dismissal instead of
    /// racing it.
    @State private var nextAlert: (title: String, message: String)?
    @State private var isUninstalling = false
    @State private var largeFiles: [LargeFile] = []
    @State private var isLoadingFiles = false
    @State private var filesError: String?
    @State private var filesLoaded = false
    @State private var filesQuery = ""
    @State private var isTrashingFile = false
    @State private var actionErrorTitle = ""
    @State private var actionError: String?
    @State private var dataLoaded = false

    var body: some View {
        // Filtered once here and threaded down: the body re-runs on every
        // keystroke, and the list, the count and the "no matches" state all need
        // the same answer. Trimming is free when the box is empty, so working out
        // the tab that is not on screen costs nothing.
        let appsVisible = filteredApps
        let filesVisible = filteredFiles

        PanelScaffold {
            header
        } summary: {
            volumeStrip
        } filters: {
            filterBar(
                shown: section == .apps ? appsVisible.count : filesVisible.count,
                total: section == .apps ? apps.count : largeFiles.count
            )
        } content: {
            inventory(apps: appsVisible, files: filesVisible)
        }
        .task {
            if !dataLoaded {
                await loadVolumes()
                await loadApps()
                dataLoaded = true
            }
        }
        .sheet(item: $sheet, onDismiss: presentNext) { item in
            sheetContent(item)
                // A sheet has no traffic lights, so its own Cancel/Done buttons
                // stay — and Escape has to reach them too, or a confirmation can
                // only be left through the mouse.
                .onExitCommand { sheet = nil }
        }
        .alert(
            actionErrorTitle,
            isPresented: .constant(actionError != nil),
            presenting: actionError
        ) { _ in
            Button(settings.t("done")) { actionError = nil }
        } message: { error in
            Text(error)
        }
    }

    @ViewBuilder
    private func sheetContent(_ item: StorageSheet) -> some View {
        switch item {
        case .confirmApp(let app):
            UninstallConfirmationSheet(
                app: app,
                onCancel: { sheet = nil },
                onConfirm: { Task { await performUninstall(app) } }
            )
        case .confirmFile(let file):
            LargeFileTrashSheet(
                file: file,
                onCancel: { sheet = nil },
                onConfirm: { Task { await performTrash(file) } }
            )
        }
    }

    /// The scrolling half of the window: the inline result card, then whichever
    /// inventory the picker names. Above the list, not over it — after the action
    /// the user should still be able to read what is left.
    private func inventory(apps: [InstalledApp], files: [LargeFile]) -> some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.m) {
            if let result {
                StorageResultCard(
                    report: result.report,
                    title: settings.t(result.titleKey),
                    onClose: { self.result = nil }
                )
                // Capped: a report listing dozens of leftovers must never cost the
                // list more than a peek at the outcome.
                .frame(maxHeight: 160)
            }

            switch section {
            case .apps: appsBody(apps)
            case .files: largeFilesBody(files)
            }
        }
    }

    /// Reclaimable is one number, so it rides in the header beside the title
    /// instead of claiming a full-width row under the volumes. Its explanation
    /// moved onto the chip itself, where the thing it explains is.
    private var header: some View {
        PanelHeader(
            title: settings.t("storage"),
            subtitle: space.volumeName?.isEmpty == false ? space.volumeName : nil
        ) {
            if let reclaimable {
                reclaimableStat(reclaimable)
            }
        }
    }

    /// One row per volume. The two-column card grid this replaced spent ~140pt per
    /// pair of disks on a percent line, a bar and three labelled tiles; a strip
    /// row says the same thing in about 50pt, so a Mac with one disk spends one
    /// short row rather than a screenful of chrome.
    ///
    /// No "Volumes" heading above it: every row names its own volume, and a label
    /// over one row is a row of chrome for nothing. The name is still spoken, as
    /// the strip's accessibility label.
    private var volumeStrip: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            ForEach(volumes) { volume in
                VolumeRow(volume: volume)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(settings.t("volumesTitle"))
    }

    /// Apps or files, what it matches, and how to type a query: one row. It was a
    /// divider, then a picker, then a search, then a heading with a count.
    private func filterBar(shown: Int, total: Int) -> some View {
        PanelFilterBar(placeholder: searchPlaceholder, text: searchBinding) {
            Picker(settings.t("storage"), selection: $section) {
                Text(settings.t("appsTitle")).tag(StorageSection.apps)
                Text(settings.t("largeFilesTitle")).tag(StorageSection.files)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(settings.t("storage"))
            .onChange(of: section) { _, next in
                // Walking the home directory is slower than reading an app
                // list, so it waits until the tab is actually opened.
                if next == .files, !filesLoaded {
                    filesLoaded = true
                    Task { await loadLargeFiles() }
                }
            }
        } trailing: {
            HStack(spacing: PanelStyle.Space.s) {
                if isInventoryLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                if total > 0 {
                    countChip(shown, of: total, filtered: isInventoryFiltering)
                        .accessibilityLabel(inventoryCountLabel(shown: shown, total: total))
                }
            }
        }
    }

    /// Each tab keeps its own query: typing in Files must not silently reset
    /// what Apps was showing.
    private var searchBinding: Binding<String> {
        switch section {
        case .apps: $appsQuery
        case .files: $filesQuery
        }
    }

    private var searchPlaceholder: String {
        switch section {
        case .apps: settings.t("searchApps")
        case .files: settings.t("searchFiles")
        }
    }

    private var isInventoryLoading: Bool {
        switch section {
        case .apps: isLoadingApps
        case .files: isLoadingFiles
        }
    }

    private var isInventoryFiltering: Bool {
        switch section {
        case .apps: !needle(appsQuery).isEmpty
        case .files: !needle(filesQuery).isEmpty
        }
    }

    /// The same number, spoken with the current tab's own noun.
    private func inventoryCountLabel(shown: Int, total: Int) -> String {
        countLabel(
            shown,
            of: total,
            filtered: isInventoryFiltering,
            key: section == .apps ? "appsCount" : "largeFilesCount"
        )
    }

    /// Four distinct states: still loading, failed with a retry, the list, or a
    /// filter that hides everything. The last one is not an empty list.
    @ViewBuilder
    private func appsBody(_ visible: [InstalledApp]) -> some View {
        if let error = appsError {
            PanelStateView(
                kind: .error,
                message: error,
                title: settings.t("appsTitle"),
                actionTitle: settings.t("retry"),
                action: { Task { await loadApps() } }
            )
        } else if apps.isEmpty {
            // Zero applications is a real answer, not a reason to spin.
            PanelStateView(
                kind: isLoadingApps ? .loading : .empty,
                message: isLoadingApps ? settings.t("busyApps") : settings.t("appsEmpty")
            )
            .frame(minHeight: 120)
        } else if visible.isEmpty {
            // A filter that hides everything is not the same as an empty list.
            NoMatchesView()
                .frame(minHeight: 120)
        } else {
            ScrollView {
                LazyVStack(spacing: PanelStyle.Space.s) {
                    ForEach(visible) { app in
                        AppRow(
                            app: app,
                            isUninstalling: isUninstalling,
                            onUninstall: { sheet = .confirmApp(app) }
                        )
                    }
                }
            }
        }
    }

    /// The same three states as the application list: loading, failed with a
    /// retry, or the rows.
    @ViewBuilder
    private func largeFilesBody(_ visible: [LargeFile]) -> some View {
        if let error = filesError {
            PanelStateView(
                kind: .error,
                message: error,
                title: settings.t("largeFilesTitle"),
                actionTitle: settings.t("retry"),
                action: { Task { await loadLargeFiles() } }
            )
        } else if largeFiles.isEmpty {
            PanelStateView(
                kind: isLoadingFiles ? .loading : .empty,
                message: isLoadingFiles ? settings.t("busyLargeFiles") : settings.t("largeFilesEmpty")
            )
            .frame(minHeight: 120)
        } else if visible.isEmpty {
            NoMatchesView()
                .frame(minHeight: 120)
        } else {
            ScrollView {
                LazyVStack(spacing: PanelStyle.Space.s) {
                    ForEach(visible) { file in
                        LargeFileRow(
                            file: file,
                            isTrashing: isTrashingFile,
                            onTrash: { sheet = .confirmFile(file) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Filtering

    /// A trimmed, lowercased needle; an all-whitespace box is not a filter.
    private func needle(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredApps: [InstalledApp] {
        let needle = needle(appsQuery)
        guard !needle.isEmpty else { return apps }
        return apps.filter { $0.matches(needle) }
    }

    private var filteredFiles: [LargeFile] {
        let needle = needle(filesQuery)
        guard !needle.isEmpty else { return largeFiles }
        return largeFiles.filter { $0.matches(needle) }
    }

    /// The count pill. With a filter on it reads "3 of 40" instead of pretending
    /// the whole list is what the user is looking at.
    private func countChip(_ shown: Int, of total: Int, filtered: Bool) -> some View {
        Text(filtered
            ? settings.t("filterShowing", ["shown": "\(shown)", "total": "\(total)"])
            : settings.t("itemMany", ["n": "\(total)"]))
            .font(PanelFont.number(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(PanelStyle.rowFill, in: .capsule)
    }

    /// The same number, spoken with the panel's own noun.
    private func countLabel(_ shown: Int, of total: Int, filtered: Bool, key: String) -> String {
        filtered
            ? settings.t("filterShowing", ["shown": "\(shown)", "total": "\(total)"])
            : settings.t(key, ["n": "\(total)"])
    }

    /// Reclaimable as a header chip. The explanation is on the chip's own info
    /// glyph rather than on a row of its own, so the caveat is available exactly
    /// where the number is read.
    private func reclaimableStat(_ reclaimable: UInt64) -> some View {
        HStack(spacing: PanelStyle.Space.xs) {
            Text(settings.t("reclaimableMetric"))
                .font(PanelFont.secondary)
                .foregroundStyle(.secondary)
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .help(settings.t("reclaimableHelp"))
                .accessibilityLabel(settings.t("reclaimableHelp"))
            Text(ByteFormat.string(reclaimable))
                .font(PanelFont.number(.semibold))
        }
        .padding(.horizontal, PanelStyle.Space.s)
        .padding(.vertical, PanelStyle.Space.xs)
        .background(PanelStyle.rowFill, in: .capsule)
        .help(notes)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(settings.t("reclaimableMetric")): \(ByteFormat.string(reclaimable)). \(notes)")
    }

    /// Both sentences the old row carried: what the number means, and that the
    /// engine measured it. They are one tooltip now because they are one fact.
    private var notes: String {
        "\(settings.t("reclaimableHelp")) \(settings.t("storageNote"))"
    }

    /// Reading volume metadata is synchronous disk I/O, and a network or
    /// external volume can take seconds to answer — on the main actor that is a
    /// frozen window, so it runs on a detached task and only the result hops back.
    private func loadVolumes() async {
        volumes = await Task.detached { Self.readVolumes() }.value
    }

    private nonisolated static func readVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var result: [VolumeInfo] = []
        for url in urls {
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard let total = values.volumeTotalCapacity,
                      let available = values.volumeAvailableCapacity,
                      total > 0, available >= 0 else { continue }
                let totalU = UInt64(total)
                let availableU = UInt64(available)
                let used = totalU - availableU
                let name = values.volumeName ?? url.lastPathComponent
                result.append(VolumeInfo(name: name, total: totalU, used: used, free: availableU))
            } catch {
                continue
            }
        }
        return result
    }

    private func loadApps() async {
        isLoadingApps = true
        appsError = nil
        do {
            let cli = try DustlessCLI.resolve()
            let fetchedApps = try await cli.apps()
            apps = fetchedApps.sorted { $0.bytes > $1.bytes }
        } catch {
            appsError = error.localizedDescription
        }
        isLoadingApps = false
    }

    private func performUninstall(_ app: InstalledApp) async {
        isUninstalling = true
        defer { isUninstalling = false }
        do {
            let cli = try DustlessCLI.resolve()
            let report = try await cli.uninstallApp(path: app.path)
            // A state write, not a presentation: the report appears in the window
            // without waiting for the confirmation to finish dismissing.
            result = StorageResult(report: report, titleKey: "appsUninstalled")
            sheet = nil
            await loadApps()
        } catch {
            fail(error, title: settings.t("appsUninstall"))
        }
    }

    private func loadLargeFiles() async {
        isLoadingFiles = true
        filesError = nil
        do {
            let cli = try DustlessCLI.resolve()
            largeFiles = try await cli.largefiles()
        } catch {
            filesError = error.localizedDescription
        }
        isLoadingFiles = false
    }

    private func performTrash(_ file: LargeFile) async {
        isTrashingFile = true
        defer { isTrashingFile = false }
        do {
            let cli = try DustlessCLI.resolve()
            let report = try await cli.deleteLargeFile(path: file.path)
            result = StorageResult(report: report, titleKey: "largeFilesTrashed")
            sheet = nil
            largeFiles.removeAll { $0.path == file.path }
            // The report is on screen already; re-reading the walk is not worth
            // the seconds it takes when the tab is closed again.
        } catch {
            fail(error, title: settings.t("largeFilesTitle"))
        }
    }

    private func fail(_ error: Error, title: String) {
        let message = error.localizedDescription
        // An alert cannot present on top of a sheet. Dismiss the sheet first and
        // let `presentNext` raise the alert once it is gone; with no sheet open
        // there is nothing to wait for.
        if sheet == nil {
            actionErrorTitle = title
            actionError = message
        } else {
            nextAlert = (title, message)
            sheet = nil
        }
    }

    /// Raises whatever error an action queued, but only after the confirmation
    /// sheet it came from has finished dismissing.
    private func presentNext() {
        guard let alert = nextAlert else { return }
        Task { @MainActor in
            // A beat for the dismissal animation to settle; without it SwiftUI
            // can be asked to present while it is still dismissing.
            try? await Task.sleep(nanoseconds: 260_000_000)
            nextAlert = nil
            actionErrorTitle = alert.title
            actionError = alert.message
        }
    }
}

struct VolumeInfo: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let total: UInt64
    let used: UInt64
    let free: UInt64

    var usedPercent: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total)
    }
}

/// One volume as a strip row: name, used percent, a hairline bar, and one caption
/// carrying all three numbers. The card this replaced needed three metric tiles to
/// say the same, which is why one disk used to cost more than 140pt of a 620pt
/// window.
struct VolumeRow: View {
    let volume: VolumeInfo
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.xs) {
            HStack(spacing: PanelStyle.Space.s) {
                Text(volume.name)
                    .font(PanelFont.emphasis(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: PanelStyle.Space.s)
                Text(volume.usedPercent, format: .percent.precision(.fractionLength(0)))
                    .font(PanelFont.number())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: volume.usedPercent)
                .frame(height: 3)
                .help(settings.t("volumeUsageHelp", ["name": volume.name]))

            Text(settings.t("volumeCaption", [
                "used": ByteFormat.string(volume.used),
                "free": ByteFormat.string(volume.free),
                "total": ByteFormat.string(volume.total),
            ]))
            .font(PanelFont.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .padding(.horizontal, PanelStyle.Space.m)
        .padding(.vertical, PanelStyle.Space.xs)
        .panelCard(PanelStyle.rowFill)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct AppRow: View {
    let app: InstalledApp
    var isUninstalling: Bool = false
    let onUninstall: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: PanelStyle.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(PanelFont.emphasis())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(app.bundleId)
                    .font(PanelFont.mono(10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: PanelStyle.Space.s)

            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormat.string(app.bytes))
                    .font(PanelFont.number())
                    .foregroundStyle(.primary)
                Text(settings.t("appsRelatedCount", ["n": "\(app.relatedPaths.count)"]))
                    .font(PanelFont.caption)
                    .foregroundStyle(.secondary)
            }

            Button(settings.t("appsUninstall"), role: .destructive, action: onUninstall)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isUninstalling)
                .help(settings.t("appsUninstallHelp", ["name": app.name]))
                .accessibilityLabel(settings.t("appsUninstallNamed", ["name": app.name]))
        }
        .padding(.horizontal, PanelStyle.Space.m)
        .padding(.vertical, PanelStyle.Space.s)
        .panelCard(PanelStyle.rowFill)
        .pathContextMenu(app.path)
        .accessibilityElement(children: .contain)
    }
}

/// One big file. The destructive control is the same red "Move to Trash"
/// button the application list uses, and it opens a sheet that names the exact
/// path before anything moves.
struct LargeFileRow: View {
    let file: LargeFile
    var isTrashing: Bool = false
    let onTrash: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: PanelStyle.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(PanelFont.emphasis())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.path)
                    .font(PanelFont.mono(10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: PanelStyle.Space.s)

            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormat.string(file.size))
                    .font(PanelFont.number())
                    .foregroundStyle(.primary)
                Text(file.modified, format: .dateTime.year().month(.abbreviated).day())
                    .font(PanelFont.caption)
                    .foregroundStyle(.secondary)
            }

            Button(settings.t("appsMoveToTrash"), role: .destructive, action: onTrash)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isTrashing)
                .help(settings.t("largeFilesTrashHelp", ["name": file.name]))
                .accessibilityLabel(settings.t("largeFilesTrashHelp", ["name": file.name]))
        }
        .padding(.horizontal, PanelStyle.Space.m)
        .padding(.vertical, PanelStyle.Space.s)
        .panelCard(PanelStyle.rowFill)
        .pathContextMenu(file.path)
        .accessibilityElement(children: .contain)
    }
}

/// Names the one path it is about to move, so the confirm button is never a
/// guess. There is no bulk form here: the engine deletes a single file per call.
struct LargeFileTrashSheet: View {
    let file: LargeFile
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
                HStack(spacing: PanelStyle.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(settings.t("appsTrashTitle"))
                        .font(PanelFont.emphasis(.semibold))
                }
                Text(file.name)
                    .font(PanelFont.emphasis())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(settings.t("largeFilesTrashBody"))
                    .font(PanelFont.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PanelStyle.Space.l)

            Divider()

            AppUninstallRow(name: file.name, path: file.path, bytes: file.size, isApp: false)

            Divider()

            HStack(spacing: PanelStyle.Space.m) {
                Button(settings.t("confirmCancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(role: .destructive, action: onConfirm) {
                    Text(settings.t("appsMoveToTrash"))
                        .frame(minWidth: 160)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(PanelStyle.Space.l)
            .background(.ultraThinMaterial)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 300)
    }
}

struct UninstallConfirmationSheet: View {
    let app: InstalledApp
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // App itself
                    AppUninstallRow(
                        name: app.name,
                        path: app.path,
                        bytes: app.bytes,
                        isApp: true
                    )
                    Divider().opacity(0.4).padding(.horizontal, PanelStyle.Space.m)

                    // Related files
                    ForEach(app.relatedPaths, id: \.self) { related in
                        AppUninstallRow(
                            name: (related as NSString).lastPathComponent,
                            path: related,
                            bytes: nil,
                            isApp: false
                        )
                        Divider().opacity(0.4).padding(.horizontal, PanelStyle.Space.m)
                    }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 580, idealWidth: 680, minHeight: 380, idealHeight: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            HStack(spacing: PanelStyle.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(settings.t("appsTrashTitle"))
                    .font(PanelFont.emphasis(.semibold))
            }
            Text(app.name)
                .font(PanelFont.emphasis())
                .lineLimit(1)
                .truncationMode(.middle)
            Text(settings.t("appsTrashBody", ["n": "\(app.relatedPaths.count)"]))
                .font(PanelFont.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PanelStyle.Space.l)
    }

    private var footer: some View {
        VStack(spacing: PanelStyle.Space.m) {
            HStack {
                Text(settings.t("totalLabel"))
                    .font(PanelFont.body)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ByteFormat.string(totalBytes))
                    .font(PanelFont.number(.semibold))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(settings.t("confirmTotal", ["amount": ByteFormat.string(totalBytes)]))

            HStack(spacing: PanelStyle.Space.m) {
                Button(settings.t("confirmCancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(role: .destructive, action: onConfirm) {
                    Text(settings.t("appsMoveToTrash"))
                        .frame(minWidth: 160)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(PanelStyle.Space.l)
        .background(.ultraThinMaterial)
    }

    private var totalBytes: UInt64 {
        // The CLI reports the leftover paths but not their individual sizes.
        app.bytes
    }
}

struct AppUninstallRow: View {
    let name: String
    let path: String
    let bytes: UInt64?
    let isApp: Bool

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(alignment: .top, spacing: PanelStyle.Space.m) {
            Image(systemName: isApp ? "app.fill" : "doc")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isApp ? .blue : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 12, weight: isApp ? .medium : .regular))
                    .textSelection(.enabled)
                Text(path)
                    .font(PanelFont.mono(10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                    .accessibilityLabel(settings.t("pathA11y", ["path": path]))
            }

            Spacer(minLength: PanelStyle.Space.m)

            if let bytes {
                Text(ByteFormat.string(bytes))
                    .font(PanelFont.number())
                    .frame(width: 70, alignment: .trailing)
            }
        }
        .padding(.vertical, PanelStyle.Space.s)
        .padding(.horizontal, PanelStyle.Space.m)
        .pathContextMenu(path)
        .accessibilityElement(children: .combine)
    }
}

/// The outcome of an uninstall or a trash, drawn inline in the inventory.
///
/// This was a modal result sheet ending in Done, which asked for a second
/// acknowledgement nobody needed: the action had already finished and the list
/// behind it shows what is left. A card says the same thing without blocking,
/// and its corner × is a card affordance rather than a page exit — nothing is
/// waiting behind it.
struct StorageResultCard: View {
    let report: UninstallReport
    /// "Uninstalled" reads wrong for a file that was only moved to the Trash.
    let title: String
    let onClose: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            header

            // Bounded: one app can report dozens of leftover paths, and a report
            // that grows the window is worse than a report you scroll.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(report.outcomes) { outcome in
                        outcomeRow(outcome)
                    }
                }
            }
        }
        .padding(PanelStyle.Space.m)
        .panelCard(PanelStyle.rowFill)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: PanelStyle.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(PanelFont.emphasis(.semibold))
                Text(settings.t("appsResultSummary", [
                    "freed": ByteFormat.string(report.summary.totalBytes),
                    "count": "\(report.outcomes.count)",
                ]))
                .font(PanelFont.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(settings.t("close"))
            .accessibilityLabel(settings.t("close"))
        }
    }

    private func outcomeRow(_ outcome: UninstallOutcome) -> some View {
        // One lookup, not one per line: the glyph and its spoken label must agree.
        let status = settings.t(statusKey(for: outcome.status))
        return HStack(alignment: .top, spacing: PanelStyle.Space.m) {
            Image(systemName: symbol(for: outcome.status))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint(for: outcome.status))
                .frame(width: 14)
                .help(settings.t("outcomeStatus", ["status": status]))
                .accessibilityLabel(settings.t("outcomeStatus", ["status": status]))
            VStack(alignment: .leading, spacing: 3) {
                Text(outcome.path)
                    .font(PanelFont.mono(11.5))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                if !outcome.detail.isEmpty {
                    Text(outcome.detail)
                        .font(PanelFont.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(nil)
                }
            }
            Spacer(minLength: PanelStyle.Space.m)
            Text(ByteFormat.string(outcome.bytes))
                .font(PanelFont.number())
                .frame(width: 66, alignment: .trailing)
        }
        .padding(.vertical, PanelStyle.Space.s)
        .padding(.horizontal, 2)
        .pathContextMenu(outcome.path)
    }

    private func symbol(for status: UninstallOutcome.Status) -> String {
        switch status {
        case .trashed: "checkmark.circle.fill"
        case .purged: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func tint(for status: UninstallOutcome.Status) -> Color {
        switch status {
        case .trashed: .green
        case .purged: .green
        case .skipped: .secondary
        case .failed: .red
        }
    }

    /// Reuses the shared cleanup vocabulary, so this reads like the rest of the panel.
    private func statusKey(for status: UninstallOutcome.Status) -> String {
        switch status {
        case .trashed: "deleted"
        case .purged: "deleted"
        case .skipped: "skipped"
        case .failed: "failed"
        }
    }
}