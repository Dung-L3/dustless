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

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var report: ScanReport?
    /// When the report on screen was produced. `ScanReport` carries no
    /// timestamp of its own, so the Overview provenance line has to be told the
    /// moment a report landed rather than guess it from a file's mtime.
    @Published private(set) var scannedAt: Date?
    @Published private(set) var lastApply: ApplyReport?
    @Published private(set) var memoryReport: MemoryReport?
    @Published private(set) var diskSpace: DiskSpace?
    @Published private(set) var engineError: L10nText?
    @Published private(set) var busyMessage: L10nText?
    @Published var showingConfirmation = false
    /// Whether the inline cleanup result card is on screen. The card has no
    /// modal behind it any more — only the confirmation takes the window over,
    /// because only the confirmation asks for a decision — but it is dismissed
    /// deliberately, so it still needs its own flag.
    @Published var showingCleanupResult = false
    @Published var selection: Set<String> = []
    @Published var tierTab: TierTab = .safe
    /// The findings list's own filter, held here rather than in the view: the
    /// detail pane is rebuilt on every module switch, so `@State` would drop the
    /// query the user typed the moment they looked at Memory.
    @Published var findingsQuery = ""

    // Independent loading state for Memory/Storage windows — does NOT touch main phase/cli
    @Published private(set) var memoryPhase: LoadPhase = .idle
    /// When the last successful memory read landed, so a module switch can reuse
    /// it instead of paying for `ram --json` again.
    private(set) var memoryLoadedAt: Date?
    @Published private(set) var memoryError: L10nText?
    @Published private(set) var storagePhase: LoadPhase = .idle
    @Published private(set) var storageError: L10nText?

    // Storage inventory: the volume strip and the two lists in StorageView.
    // Held here rather than in the view because StorageView is rebuilt on every
    // module switch — its @State used to throw the inventory away, so every visit
    // re-read the app list and every mounted volume. A last-loaded timestamp lets
    // a return inside the window repaint from cache and re-read only when the
    // list is genuinely old.
    @Published private(set) var storageVolumes: [VolumeInfo] = []
    @Published private(set) var storageApps: [InstalledApp] = []
    @Published private(set) var storageLargeFiles: [LargeFile] = []
    @Published private(set) var isLoadingStorageApps = false
    @Published private(set) var isLoadingStorageFiles = false
    @Published private(set) var storageAppsError: L10nText?
    @Published private(set) var storageFilesError: L10nText?
    /// When the last successful read of each inventory landed, so a module
    /// switch can reuse it instead of paying for the engine again. `nil` until
    /// the first success, which is how a failed read retries on the next visit.
    private(set) var storageVolumesLoadedAt: Date?
    private(set) var storageAppsLoadedAt: Date?
    private(set) var storageFilesLoadedAt: Date?

    private var cli: DustlessCLI?

    var canClean: Bool {
        guard report != nil, phase == .ready else { return false }
        return !selectedFindings.isEmpty
    }

    /// While the engine is being located or is walking the disk. Every control
    /// that would start a second run, or that acts on a list about to be
    /// replaced, is held for this long — not merely ignored by a guard inside
    /// `rescan()`, which looks live and does nothing.
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
            self.report = report
            self.scannedAt = Date()
            selection = report.initialSelection
            // Both, together: a card with no report behind it and an Overview
            // "freed" stat that disagrees with the list under it are the two
            // ways the same rescan can leave the window telling two stories.
            lastApply = nil
            showingCleanupResult = false
            busyMessage = nil
            phase = .ready
        } catch {
            // A failed rescan keeps the last good report, its age and its
            // selection on screen: stale numbers beat a blank panel, and the
            // error banner is how the user learns they are stale. With a report
            // to stand on the engine handle is still live, so it stays too —
            // otherwise the list would be readable and unactionable.
            if report == nil { cli = nil }
            engineError = Self.describe(error)
            busyMessage = nil
            phase = report == nil ? .idle : .ready
        }
    }

    /// Clears the stale-report banner without touching the report itself.
    func dismissEngineError() { engineError = nil }

    func clean() async {
        // Snapshot once: the engine is handed this list and nothing else, so the
        // paths counted in the busy message are the paths that get deleted.
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
            report = fresh
            scannedAt = Date()
            selection = fresh.initialSelection
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

    /// Reuses the last successful read when it is recent. The dashboard and the
    /// Memory module both appear on a module switch, which is not a reason to
    /// re-read the whole process table.
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

    // MARK: - Storage inventory

    /// Reuses the last successful read when it is recent. A module switch is not
    /// a reason to re-read every mounted volume or the app list; a stale panel
    /// is. The uninstall path and the retry buttons call the `fetch…` versions
    /// directly, which never consult the window.
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

    /// Reads every mounted volume. Synchronous disk I/O, and a network or
    /// external volume can take seconds to answer — on the main actor that is a
    /// frozen window, so it runs on a detached task and only the result hops back.
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

    /// Always re-reads the app list, bypassing the staleness window. The
    /// uninstall path and the retry button both force a fresh answer.
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

    /// Always re-walks the home directory, bypassing the staleness window. The
    /// retry button forces it; a trash just removes the row and leaves the walk
    /// for the next stale visit.
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

    /// The app is gone now, so it leaves the list on this run rather than when
    /// the next read finishes: a slow or failed refresh must not leave a deleted
    /// bundle sitting in the inventory.
    func removeStorageApp(atPath path: String) {
        storageApps.removeAll { $0.path == path }
    }

    /// The file was moved to the Trash, so it leaves the list on this run.
    func removeStorageFile(atPath path: String) {
        storageLargeFiles.removeAll { $0.path == path }
    }

    static func describe(_ error: Error) -> L10nText {
        if let error = error as? DustlessError { return error.localized }
        if let error = error as? BinaryLocationError { return error.localized }
        return L10nText("errGeneric", ["detail": error.localizedDescription])
    }
}
