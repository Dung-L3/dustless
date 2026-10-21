import DustlessKit
import SwiftUI
import AppKit

enum StorageSection: String, Identifiable {
    case apps
    case files

    var id: String { rawValue }
}

struct StorageView: View {
    let space: DiskSpace
    let reclaimable: UInt64?
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: ScanStore
    @StateObject private var control = StorageControl()

    @State private var section: StorageSection = .apps
    @State private var appsQuery = ""
    @State private var filesQuery = ""

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
        .sheet(item: $control.sheet, onDismiss: { control.presentNext() }) { item in
            sheetContent(item)
                .onExitCommand { control.sheet = nil }
        }
        .alert(
            settings.t(control.actionErrorTitleKey),
            isPresented: actionErrorPresented,
            presenting: control.actionError
        ) { _ in
            Button(settings.t("done")) { control.dismissError() }
        } message: { error in
            Text(settings.text(error))
        }
    }

    private var actionErrorPresented: Binding<Bool> {
        Binding(
            get: { control.actionError != nil },
            set: { if !$0 { control.dismissError() } }
        )
    }

    @ViewBuilder
    private func sheetContent(_ item: StorageSheet) -> some View {
        switch item {
        case .confirmApp(let app):
            UninstallConfirmationSheet(
                app: app,
                onCancel: { control.sheet = nil },
                onConfirm: { Task { await control.uninstall(app, store: store) } }
            )
        case .confirmFile(let file):
            LargeFileTrashSheet(
                file: file,
                onCancel: { control.sheet = nil },
                onConfirm: { Task { await control.trash(file, store: store) } }
            )
        }
    }

    private func inventory(apps: [InstalledApp], files: [LargeFile]) -> some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.m) {
            if let result = control.result {
                StorageResultCard(
                    report: result.report,
                    title: settings.t(result.titleKey),
                    onClose: { control.clearResult() }
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
            subtitle: space.volumeName?.isEmpty == false ? space.volumeName : nil,
            identifier: "storage.header"
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
        PanelFilterBar(
            placeholder: searchPlaceholder,
            text: searchBinding,
            filter: {
                Picker(settings.t("storage"), selection: $section) {
                    Text(settings.t("appsTitle"))
                        .tag(StorageSection.apps)
                        .accessibilityIdentifier("storage.section.apps")
                    Text(settings.t("largeFilesTitle"))
                        .tag(StorageSection.files)
                        .accessibilityIdentifier("storage.section.files")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(settings.t("storage"))
                .onChange(of: section) { _, next in
                    if next == .files {
                        Task { await store.ensureStorageFiles() }
                    }
                }
            },
            trailing: {
                HStack(spacing: PanelStyle.Space.s) {
                    if isInventoryLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if total > 0 {
                        countChip(shown, of: total, filtered: isInventoryFiltering)
                            .accessibilityLabel(inventoryCountLabel(shown: shown, total: total))
                            .accessibilityIdentifier("storage.count")
                    }
                }
            },
            searchIdentifier: "storage.search"
        )
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
                action: { Task { await store.fetchStorageApps() } },
                identifier: "storage.apps.state",
                actionIdentifier: "storage.apps.retry"
            )
        } else if store.storageApps.isEmpty {
            PanelStateView(
                kind: store.isLoadingStorageApps ? .loading : .empty,
                message: store.isLoadingStorageApps ? settings.t("busyApps") : settings.t("appsEmpty"),
                identifier: "storage.apps.state"
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
                            isUninstalling: control.isUninstalling,
                            onUninstall: { control.sheet = .confirmApp(app) }
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
                action: { Task { await store.fetchStorageFiles() } },
                identifier: "storage.files.state",
                actionIdentifier: "storage.files.retry"
            )
        } else if store.storageLargeFiles.isEmpty {
            PanelStateView(
                kind: store.isLoadingStorageFiles ? .loading : .empty,
                message: store.isLoadingStorageFiles ? settings.t("busyLargeFiles") : settings.t("largeFilesEmpty"),
                identifier: "storage.files.state"
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
                            isTrashing: control.isTrashingFile,
                            onTrash: { control.sheet = .confirmFile(file) }
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
}
