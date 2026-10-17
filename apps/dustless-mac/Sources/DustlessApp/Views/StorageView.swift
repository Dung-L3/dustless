import DustlessKit
import SwiftUI
import AppKit

enum StorageSection: String, Identifiable {
    case apps
    case files

    var id: String { rawValue }
}

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

struct StorageResult: Identifiable {
    let report: UninstallReport
    let titleKey: String

    var id: String { report.id }
}

struct StorageView: View {
    let space: DiskSpace
    let reclaimable: UInt64?
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: ScanStore

    @State private var section: StorageSection = .apps
    @State private var appsQuery = ""
    @State private var sheet: StorageSheet?
    @State private var result: StorageResult?
    @State private var nextAlert: (titleKey: String, message: L10nText)?
    @State private var isUninstalling = false
    @State private var filesQuery = ""
    @State private var isTrashingFile = false
    @State private var actionErrorTitleKey = ""
    @State private var actionError: L10nText?

    var body: some View {
        let appsVisible = filteredApps
        let filesVisible = filteredFiles

        PanelScaffold {
            header
        } summary: {
            volumeStrip
        } filters: {
            filterBar(
                shown: section == .apps ? appsVisible.count : filesVisible.count,
                total: section == .apps ? store.storageApps.count : store.storageLargeFiles.count
            )
        } content: {
            inventory(apps: appsVisible, files: filesVisible)
        }
        .task {
            await store.ensureStorageVolumes()
            await store.ensureStorageApps()
        }
        .sheet(item: $sheet, onDismiss: presentNext) { item in
            sheetContent(item)
                .onExitCommand { sheet = nil }
        }
        .alert(
            settings.t(actionErrorTitleKey),
            isPresented: actionErrorPresented,
            presenting: actionError
        ) { _ in
            Button(settings.t("done")) { actionError = nil }
        } message: { error in
            Text(settings.text(error))
        }
    }

    private var actionErrorPresented: Binding<Bool> {
        Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )
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

    private func inventory(apps: [InstalledApp], files: [LargeFile]) -> some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.m) {
            if let result {
                StorageResultCard(
                    report: result.report,
                    title: settings.t(result.titleKey),
                    onClose: { self.result = nil }
                )
                .frame(maxHeight: 160)
            }

            switch section {
            case .apps: appsBody(apps)
            case .files: largeFilesBody(files)
            }
        }
    }

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

    private var volumeStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: PanelStyle.Space.s) {
                ForEach(store.storageVolumes) { volume in
                    VolumeCard(volume: volume)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(settings.t("volumesTitle"))
    }

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
                if next == .files {
                    Task { await store.ensureStorageFiles() }
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
        case .apps: store.isLoadingStorageApps
        case .files: store.isLoadingStorageFiles
        }
    }

    private var isInventoryFiltering: Bool {
        switch section {
        case .apps: !needle(appsQuery).isEmpty
        case .files: !needle(filesQuery).isEmpty
        }
    }

    private func inventoryCountLabel(shown: Int, total: Int) -> String {
        countLabel(
            shown,
            of: total,
            filtered: isInventoryFiltering,
            key: section == .apps ? "appsCount" : "largeFilesCount"
        )
    }

    @ViewBuilder
    private func appsBody(_ visible: [InstalledApp]) -> some View {
        if let error = store.storageAppsError {
            PanelStateView(
                kind: .error,
                message: settings.text(error),
                title: settings.t("appsTitle"),
                actionTitle: settings.t("retry"),
                action: { Task { await store.fetchStorageApps() } }
            )
        } else if store.storageApps.isEmpty {
            PanelStateView(
                kind: store.isLoadingStorageApps ? .loading : .empty,
                message: store.isLoadingStorageApps ? settings.t("busyApps") : settings.t("appsEmpty")
            )
            .frame(minHeight: 120)
        } else if visible.isEmpty {
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

    @ViewBuilder
    private func largeFilesBody(_ visible: [LargeFile]) -> some View {
        if let error = store.storageFilesError {
            PanelStateView(
                kind: .error,
                message: settings.text(error),
                title: settings.t("largeFilesTitle"),
                actionTitle: settings.t("retry"),
                action: { Task { await store.fetchStorageFiles() } }
            )
        } else if store.storageLargeFiles.isEmpty {
            PanelStateView(
                kind: store.isLoadingStorageFiles ? .loading : .empty,
                message: store.isLoadingStorageFiles ? settings.t("busyLargeFiles") : settings.t("largeFilesEmpty")
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

    private func needle(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredApps: [InstalledApp] {
        let needle = needle(appsQuery)
        guard !needle.isEmpty else { return store.storageApps }
        return store.storageApps.filter { $0.matches(needle) }
    }

    private var filteredFiles: [LargeFile] {
        let needle = needle(filesQuery)
        guard !needle.isEmpty else { return store.storageLargeFiles }
        return store.storageLargeFiles.filter { $0.matches(needle) }
    }

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

    private func countLabel(_ shown: Int, of total: Int, filtered: Bool, key: String) -> String {
        filtered
            ? settings.t("filterShowing", ["shown": "\(shown)", "total": "\(total)"])
            : settings.t(key, ["n": "\(total)"])
    }

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

    private var notes: String {
        "\(settings.t("reclaimableHelp")) \(settings.t("storageNote"))"
    }

    private func performUninstall(_ app: InstalledApp) async {
        isUninstalling = true
        defer { isUninstalling = false }
        do {
            let cli = try DustlessCLI.resolve()
            let report = try await cli.uninstallApp(path: app.path, purge: true)
            result = StorageResult(report: report, titleKey: "appsUninstalled")
            sheet = nil
            store.removeStorageApp(atPath: app.path)
            await store.fetchStorageApps()
            await store.fetchStorageVolumes()
        } catch {
            fail(error, titleKey: "appsUninstall")
        }
    }

    private func performTrash(_ file: LargeFile) async {
        isTrashingFile = true
        defer { isTrashingFile = false }
        do {
            let cli = try DustlessCLI.resolve()
            let report = try await cli.deleteLargeFile(path: file.path)
            result = StorageResult(report: report, titleKey: "largeFilesTrashed")
            sheet = nil
            store.removeStorageFile(atPath: file.path)
        } catch {
            fail(error, titleKey: "largeFilesTitle")
        }
    }

    private func fail(_ error: Error, titleKey: String) {
        let message = ScanStore.describe(error)
        if sheet == nil {
            actionErrorTitleKey = titleKey
            actionError = message
        } else {
            nextAlert = (titleKey, message)
            sheet = nil
        }
    }

    private func presentNext() {
        guard let alert = nextAlert else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            nextAlert = nil
            actionErrorTitleKey = alert.titleKey
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

struct VolumeCard: View {
    let volume: VolumeInfo
    @EnvironmentObject private var settings: AppSettings

    private static let width: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.xs) {
            HStack(spacing: PanelStyle.Space.s) {
                Text(volume.name)
                    .font(PanelFont.emphasis(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: PanelStyle.Space.s)
                Text(percentText)
                    .font(PanelFont.number())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: volume.usedPercent)
                .frame(height: 3)

            Text(captionText)
                .font(PanelFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, PanelStyle.Space.m)
        .padding(.vertical, PanelStyle.Space.xs)
        .panelCard(PanelStyle.rowFill)
        .frame(width: Self.width)
        .help(spokenText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenText)
    }

    private var percentText: String {
        volume.usedPercent.formatted(.percent.precision(.fractionLength(0)))
    }

    private var captionText: String {
        settings.t("volumeCaption", [
            "used": ByteFormat.string(volume.used),
            "free": ByteFormat.string(volume.free),
            "total": ByteFormat.string(volume.total),
        ])
    }

    private var spokenText: String {
        "\(settings.t("volumeUsageHelp", ["name": volume.name, "percent": percentText])) \(captionText)"
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
                    AppUninstallRow(
                        name: app.name,
                        path: app.path,
                        bytes: app.bytes,
                        isApp: true
                    )
                    Divider().opacity(0.4).padding(.horizontal, PanelStyle.Space.m)

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
                Text(settings.t("appsPurgeTitle"))
                    .font(PanelFont.emphasis(.semibold))
            }
            Text(app.name)
                .font(PanelFont.emphasis())
                .lineLimit(1)
                .truncationMode(.middle)
            Text(settings.t("appsPurgeBody", ["n": "\(app.relatedPaths.count)"]))
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
                    Text(settings.t("appsPurgeAction"))
                        .frame(minWidth: 160)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(PanelStyle.Space.l)
        .background(.ultraThinMaterial)
    }

    private var totalBytes: UInt64 {
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

struct StorageResultCard: View {
    let report: UninstallReport
    let title: String
    let onClose: () -> Void

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            header

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
                Text(summaryText)
                    .font(PanelFont.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(summaryText)
                    .accessibilityLabel(summaryText)
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

    private var summaryText: String {
        settings.t("appsResultSummary", [
            "freed": ByteFormat.string(report.summary.totalBytes),
            "count": "\(report.outcomes.count)",
        ])
    }

    private func outcomeRow(_ outcome: UninstallOutcome) -> some View {
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

    private func statusKey(for status: UninstallOutcome.Status) -> String {
        switch status {
        case .trashed: "deleted"
        case .purged: "deleted"
        case .skipped: "skipped"
        case .failed: "failed"
        }
    }
}