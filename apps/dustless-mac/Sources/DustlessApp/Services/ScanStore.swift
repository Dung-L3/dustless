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
    @Published private(set) var lastApply: ApplyReport?
    @Published private(set) var memoryReport: MemoryReport?
    @Published private(set) var diskSpace: DiskSpace?
    @Published private(set) var engineError: L10nText?
    @Published private(set) var busyMessage: L10nText?
    @Published var showingConfirmation = false
    @Published var showingApplyResult = false
    @Published var selection: Set<String> = []
    @Published var tierTab: TierTab = .safe

    // Independent loading state for Memory/Storage windows — does NOT touch main phase/cli
    @Published private(set) var memoryPhase: LoadPhase = .idle
    @Published private(set) var memoryError: L10nText?
    @Published private(set) var storagePhase: LoadPhase = .idle
    @Published private(set) var storageError: L10nText?

    private var cli: DustlessCLI?

    var canClean: Bool {
        guard report != nil, phase == .ready else { return false }
        return !selectedFindings.isEmpty
    }

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
            selection = report.initialSelection
            lastApply = nil
            busyMessage = nil
            phase = .ready
        } catch {
            cli = nil
            report = nil
            engineError = Self.describe(error)
            busyMessage = nil
            phase = .idle
        }
    }

    func clean() async {
        guard let cli, !selectedFindings.isEmpty else { return }
        showingConfirmation = false
        phase = .scanning
        busyMessage = L10nText("busyDeleting", ["n": "\(selectedFindings.count)"])
        do {
            let result = try await cli.apply()
            lastApply = result
            showingApplyResult = true
            let fresh = try await cli.scan()
            report = fresh
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
            memoryPhase = .loaded
        } catch {
            memoryReport = nil
            memoryError = Self.describe(error)
            memoryPhase = .failed
        }
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
