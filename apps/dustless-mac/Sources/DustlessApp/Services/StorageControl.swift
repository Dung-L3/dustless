import Combine
import DustlessKit
import Foundation

enum StorageSheet: Identifiable {
    case confirmFile(LargeFile)

    var id: String {
        switch self {
        case .confirmFile(let file): "file-confirm:\(file.id)"
        }
    }
}

struct StorageResult: Identifiable {
    let report: UninstallReport
    let titleKey: String

    var id: String { report.id }
}

@MainActor
final class StorageControl: ObservableObject {
    @Published var sheet: StorageSheet?
    @Published private(set) var result: StorageResult?
    @Published private(set) var isTrashingFile = false
    @Published private(set) var actionErrorTitleKey = ""
    @Published private(set) var actionError: L10nText?

    private var nextAlert: (titleKey: String, message: L10nText)?

    func trash(_ file: LargeFile, store: ScanStore) async {
        guard !isTrashingFile else { return }
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

    func dismissError() { actionError = nil }

    func clearResult() { result = nil }

    func presentNext() {
        guard let alert = nextAlert else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            nextAlert = nil
            actionErrorTitleKey = alert.titleKey
            actionError = alert.message
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
}
