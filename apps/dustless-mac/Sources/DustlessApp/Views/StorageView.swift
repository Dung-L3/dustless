import AppKit
import DustlessKit
import SwiftUI

enum LargeFileSort: String, CaseIterable, Identifiable {
    case size
    case name
    case date

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .size: "sortSize"
        case .name: "sortName"
        case .date: "sortDate"
        }
    }
}

struct StorageView: View {
    let space: DiskSpace
    let reclaimable: UInt64?

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: ScanStore
    @StateObject private var control = StorageControl()

    @State private var filesQuery = ""
    @State private var sort: LargeFileSort = .size

    var body: some View {
        PanelScaffold {
            header
        } summary: {
            volumeStrip
        } filters: {
            filterBar
        } content: {
            inventory
        }
        .task {
            await store.ensureStorageVolumes()
            await store.ensureStorageFiles()
        }
        .sheet(item: $control.sheet, onDismiss: { control.presentNext() }) { item in
            if case .confirmFile(let file) = item {
                LargeFileTrashSheet(
                    file: file,
                    onCancel: { control.sheet = nil },
                    onConfirm: { Task { await control.trash(file, store: store) } }
                )
                .onExitCommand { control.sheet = nil }
            }
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
            HStack(spacing: Theme.Space.s) {
                ForEach(store.storageVolumes) { volume in
                    VolumeCard(volume: volume)
                }
            }
        }
        .scrollIndicators(.never)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(settings.t("volumesTitle"))
    }

    private var filterBar: some View {
        HStack(spacing: Theme.Space.s) {
            if store.isLoadingStorageFiles {
                ProgressView().controlSize(.small)
            }
            if !store.storageLargeFiles.isEmpty {
                Text(filesCountLabel(shown: filteredFiles.count, total: store.storageLargeFiles.count))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .accessibilityIdentifier("storage.count")
            }
            Spacer(minLength: Theme.Space.s)
            sortMenu
            SearchField(
                placeholder: settings.t("searchFiles"),
                text: $filesQuery,
                identifier: "storage.search"
            )
            .frame(maxWidth: Theme.Size.searchWidth)
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(LargeFileSort.allCases) { option in
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
        .accessibilityIdentifier("storage.sort")
    }

    private var inventory: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let result = control.result {
                StorageResultCard(
                    report: result.report,
                    title: settings.t(result.titleKey),
                    onClose: { control.clearResult() }
                )
                .frame(maxHeight: 190)
            }
            largeFilesBody
        }
    }

    @ViewBuilder
    private var largeFilesBody: some View {
        if let error = store.storageFilesError {
            PanelStateView(
                kind: .error,
                message: settings.text(error),
                error: error,
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
        } else if filteredFiles.isEmpty {
            PanelStateView(
                kind: .empty,
                message: settings.t("noMatches"),
                title: settings.t("largeFilesTitle"),
                identifier: "storage.files.state"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(filteredFiles.enumerated()), id: \.element.id) { index, file in
                        LargeFileRow(
                            file: file,
                            isTrashing: control.isTrashingFile,
                            onTrash: { control.sheet = .confirmFile(file) }
                        )
                        .staggeredAppear(index)
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
    }

    private var filteredFiles: [LargeFile] {
        let needle = filesQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = store.storageLargeFiles.filter { needle.isEmpty || $0.matches(needle) }
        switch sort {
        case .size:
            return base.sorted { $0.size > $1.size }
        case .name:
            return base.sorted { ($0.path as NSString).lastPathComponent.localizedStandardCompare(($1.path as NSString).lastPathComponent) == .orderedAscending }
        case .date:
            return base.sorted { $0.mtime > $1.mtime }
        }
    }

    private func filesCountLabel(shown: Int, total: Int) -> String {
        shown == total ? settings.fileCount(total) : settings.t("filterShowing", ["shown": "\(shown)", "total": "\(total)"])
    }

    private func reclaimableStat(_ reclaimable: UInt64) -> some View {
        HStack(spacing: 6) {
            Text(settings.t("reclaimableMetric"))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(ByteFormat.string(reclaimable))
                .font(Theme.Font.number(.semibold, size: 13))
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 5)
        .background(Theme.Palette.raised, in: .capsule)
        .overlay { Capsule().stroke(Theme.Palette.hairline, lineWidth: 1) }
        .help(settings.t("reclaimableHelp"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(settings.t("reclaimableMetric")): \(ByteFormat.string(reclaimable))")
        .accessibilityIdentifier("storage.reclaimable")
    }
}
