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

    static func describe(_ error: Error) -> L10nText {
        if let error = error as? DustlessError { return error.localized }
        if let error = error as? BinaryLocationError { return error.localized }
        return L10nText("errGeneric", ["detail": error.localizedDescription])
    }
}
