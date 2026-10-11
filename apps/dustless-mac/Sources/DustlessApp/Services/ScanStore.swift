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

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var report: ScanReport?
    @Published private(set) var lastApply: ApplyReport?
    @Published private(set) var engineError: String?
    @Published private(set) var busyMessage: String?
    @Published var showingConfirmation = false
    @Published var showingApplyResult = false
    @Published var selection: Set<String> = []
    @Published var tierTab: TierTab = .safe

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
        busyMessage = "Locating the dustless engine…"
        do {
            let cli = try DustlessCLI.resolve()
            self.cli = cli
            phase = .scanning
            busyMessage = "Measuring caches across every rule…"
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
        busyMessage = "Deleting \(selectedFindings.count) items…"
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

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
