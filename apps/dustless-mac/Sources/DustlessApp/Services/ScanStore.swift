import DustlessKit
import Foundation
import SwiftUI

@MainActor
final class ScanStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case resolvingEngine
        case scanning
        case ready
    }

    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    struct Preview {
        var report: ScanReport?
        var scannedAt: Date?
        var lastApply: ApplyReport?
        var memoryReport: MemoryReport?
        var diskSpace: DiskSpace?
        var storageVolumes: [VolumeInfo] = []
        var storageApps: [InstalledApp] = []
        var storageLargeFiles: [LargeFile] = []
        var selected: Set<String> = []
        var engineError: L10nText?
    }

    struct SelectionChange {
        let before: Int
        let kept: Int
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var report: ScanReport?
    @Published private(set) var scannedAt: Date?
    @Published private(set) var lastApply: ApplyReport?
    @Published private(set) var memoryReport: MemoryReport?
    @Published private(set) var diskSpace: DiskSpace?
    @Published private(set) var engineError: L10nText?
    @Published private(set) var busyMessage: L10nText?
    @Published var showingConfirmation = false
    @Published var showingCleanupResult = false
    @Published var selection: Set<String> = []
    @Published var tierTab: TierTab = .safe
    @Published var findingsQuery = ""

    @Published private(set) var memoryPhase: LoadPhase = .idle
    private(set) var memoryLoadedAt: Date?
    @Published private(set) var memoryError: L10nText?
    @Published private(set) var storagePhase: LoadPhase = .idle
    @Published private(set) var storageError: L10nText?

    @Published private(set) var storageVolumes: [VolumeInfo] = []
    @Published private(set) var storageApps: [InstalledApp] = []
    @Published private(set) var storageLargeFiles: [LargeFile] = []
    @Published private(set) var isLoadingStorageApps = false
    @Published private(set) var isLoadingStorageFiles = false
    @Published private(set) var storageAppsError: L10nText?
    @Published private(set) var storageFilesError: L10nText?
    @Published private(set) var selectionChange: SelectionChange?
    private(set) var storageVolumesLoadedAt: Date?
    private(set) var storageAppsLoadedAt: Date?
    private(set) var storageFilesLoadedAt: Date?

    private var cli: DustlessCLI?

    init(preview: Preview? = nil) {
        guard let preview else { return }
        report = preview.report
        scannedAt = preview.scannedAt
        lastApply = preview.lastApply
        memoryReport = preview.memoryReport
        diskSpace = preview.diskSpace
        storageVolumes = preview.storageVolumes
        storageApps = preview.storageApps
        storageLargeFiles = preview.storageLargeFiles
        selection = preview.selected
        engineError = preview.engineError
        phase = preview.report == nil ? .idle : .ready
        memoryPhase = preview.memoryReport == nil ? .idle : .loaded
        storagePhase = .loaded
        memoryLoadedAt = preview.memoryReport == nil ? nil : Date()
        storageVolumesLoadedAt = preview.storageVolumes.isEmpty ? nil : Date()
        storageAppsLoadedAt = preview.storageApps.isEmpty ? nil : Date()
        storageFilesLoadedAt = preview.storageLargeFiles.isEmpty ? nil : Date()
    }

    var canClean: Bool {
        guard report != nil, phase == .ready else { return false }
        return !selectedFindings.isEmpty
    }

    var isBusy: Bool { phase == .scanning || phase == .resolvingEngine }

    var selectedFindings: [Finding] {
        guard let report else { return [] }
        return report.deletable.filter { selection.contains($0.id) }
    }

    var selectedBytes: UInt64 {
        selectedFindings.reduce(0) { $0 + $1.bytes }
    }

    var selectedLockedCount: Int {
        guard let report else { return 0 }
        return report.locked.count
    }

    func rescan() async {
        guard phase != .scanning && phase != .resolvingEngine else { return }
        phase = .resolvingEngine
        engineError = nil
        busyMessage = L10nText("busyLocating")
        do {
            let cli = try DustlessCLI.resolve()
            self.cli = cli
            phase = .scanning
            busyMessage = L10nText("busyScanning")
            let report = try await cli.scan()
            apply(report, keepsApply: false)
            busyMessage = nil
            phase = .ready
        } catch {
            if report == nil { cli = nil }
            engineError = Self.describe(error)
            busyMessage = nil
            phase = report == nil ? .idle : .ready
        }
    }

    private func apply(_ report: ScanReport, keepsApply: Bool) {
        let before = selection
        let kept = before.intersection(Set(report.deletable.map(\.id)))
        self.report = report
        self.scannedAt = Date()
        selection = kept
        if keepsApply {
            selectionChange = nil
        } else {
            selectionChange = kept.count == before.count
                ? nil
                : SelectionChange(before: before.count, kept: kept.count)
        }
        if !keepsApply {
            lastApply = nil
            showingCleanupResult = false
        }
    }

    func dismissEngineError() { engineError = nil }

    func clean() async {
        guard phase == .ready else { return }
        let selected = selectedFindings
        guard let cli, !selected.isEmpty else { return }
        showingConfirmation = false
        phase = .scanning
        busyMessage = L10nText("busyDeleting", ["n": "\(selected.count)"])
        do {
            let result = try await cli.apply(only: selected.map(\.path))
            lastApply = result
            showingCleanupResult = true
            let fresh = try await cli.scan()
            apply(fresh, keepsApply: true)
            busyMessage = nil
            phase = .ready
        } catch {
            engineError = Self.describe(error)
            busyMessage = nil
            phase = .idle
        }
    }

    func toggle(_ finding: Finding) {
        guard finding.isDeletableByEngine else { return }
        if selection.contains(finding.id) {
            selection.remove(finding.id)
        } else {
            selection.insert(finding.id)
        }
    }

    func selectAll(in tab: TierTab) {
        guard let report else { return }
        selection.formUnion(tab.findings(in: report).filter(\.isDeletableByEngine).map(\.id))
    }

    func selectNone(in tab: TierTab) {
        guard let report else { return }
        selection.subtract(tab.findings(in: report).filter(\.isDeletableByEngine).map(\.id))
    }

    func fetchMemory() async {
        guard memoryPhase != .loading else { return }
        memoryPhase = .loading
        memoryError = nil
        do {
            let cli = try DustlessCLI.resolve()
            let report = try await cli.ram()
            self.memoryReport = report
            memoryLoadedAt = Date()
            memoryPhase = .loaded
        } catch {
            memoryReport = nil
            memoryLoadedAt = nil
            memoryError = Self.describe(error)
            memoryPhase = .failed
        }
    }

    func ensureMemory(maxAge: TimeInterval = 45) async {
        if let at = memoryLoadedAt, memoryReport != nil, Date().timeIntervalSince(at) < maxAge { return }
        await fetchMemory()
    }

    func fetchStorage() async {
        guard storagePhase != .loading else { return }
        storagePhase = .loading
        storageError = nil
        do {
            _ = try DustlessCLI.resolve()
            let space = DiskSpace.homeVolume()
            self.diskSpace = space
            storagePhase = .loaded
        } catch {
            diskSpace = nil
            storageError = Self.describe(error)
            storagePhase = .failed
        }
    }

    func ensureStorageVolumes(maxAge: TimeInterval = 45) async {
        if let at = storageVolumesLoadedAt, Date().timeIntervalSince(at) < maxAge { return }
        await fetchStorageVolumes()
    }

    func ensureStorageApps(maxAge: TimeInterval = 45) async {
        if let at = storageAppsLoadedAt, Date().timeIntervalSince(at) < maxAge { return }
        await fetchStorageApps()
    }

    func ensureStorageFiles(maxAge: TimeInterval = 45) async {
        if let at = storageFilesLoadedAt, Date().timeIntervalSince(at) < maxAge { return }
        await fetchStorageFiles()
    }

    func fetchStorageVolumes() async {
        storageVolumes = await Task.detached { Self.readVolumes() }.value
        storageVolumesLoadedAt = Date()
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

    func fetchStorageApps() async {
        guard !isLoadingStorageApps else { return }
        isLoadingStorageApps = true
        storageAppsError = nil
        do {
            let cli = try DustlessCLI.resolve()
            let fetched = try await cli.apps()
            storageApps = fetched.sorted { $0.bytes > $1.bytes }
            storageAppsLoadedAt = Date()
        } catch {
            storageAppsError = Self.describe(error)
        }
        isLoadingStorageApps = false
    }

    func fetchStorageFiles() async {
        guard !isLoadingStorageFiles else { return }
        isLoadingStorageFiles = true
        storageFilesError = nil
        do {
            let cli = try DustlessCLI.resolve()
            storageLargeFiles = try await cli.largefiles()
            storageFilesLoadedAt = Date()
        } catch {
            storageFilesError = Self.describe(error)
        }
        isLoadingStorageFiles = false
    }

    func removeStorageApp(atPath path: String) {
        storageApps.removeAll { $0.path == path }
    }

    func removeStorageFile(atPath path: String) {
        storageLargeFiles.removeAll { $0.path == path }
    }

    static func describe(_ error: Error) -> L10nText {
        if let error = error as? DustlessError { return error.localized }
        if let error = error as? BinaryLocationError { return describe(error) }
        return L10nText("errGeneric", ["detail": error.localizedDescription])
    }

    static func describe(_ error: BinaryLocationError) -> L10nText {
        switch error {
        case .notFound, .notExecutable:
            return error.localized
        case .notAnEngine(let url, let reason):
            if reason.contains("regular file") { return L10nText("errNotARegularFile", ["path": url.path]) }
            if reason.contains("executable program") { return L10nText("errNotAnExecutable", ["path": url.path]) }
            return L10nText("errNotAnEngine", ["path": url.path])
        }
    }
}