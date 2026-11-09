import AppKit
import DustlessKit
import Foundation

@MainActor
final class ApplicationsControl: ObservableObject {
    @Published var pendingSheet: InstalledApp?
    @Published private(set) var result: UninstallReport?
    @Published private(set) var resultIsPartial = false
    @Published private(set) var resultIsFailure = false
    @Published private(set) var workingApp: String?
    @Published private(set) var isQuitting = false
    @Published private(set) var error: L10nText?

    var isWorking: Bool { workingApp != nil }

    func isRunning(_ app: InstalledApp) -> Bool {
        !RunningAppIdentity.running(bundleId: app.bundleId, appPath: app.path).isEmpty
    }

    func requestUninstall(_ app: InstalledApp) {
        guard !isWorking, !app.isProtected else { return }
        pendingSheet = app
    }

    func cancel() {
        guard !isWorking else { return }
        pendingSheet = nil
    }

    func uninstall(
        _ app: InstalledApp,
        includeRelated: Bool,
        purge: Bool,
        store: ScanStore
    ) async {
        guard !isWorking else { return }
        workingApp = app.path
        error = nil
        isQuitting = false
        defer {
            workingApp = nil
            isQuitting = false
        }

        if !(await quitIfNeeded(app)) {
            let message = error
            pendingSheet = nil
            error = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.error = message }
            return
        }

        do {
            let cli = try DustlessCLI.resolve()
            let report = try await cli.uninstallApp(
                path: app.path,
                purge: purge,
                includeRelated: includeRelated
            )
            result = report
            let moved = report.summary.trashed + report.summary.purged
            resultIsPartial = report.summary.failed > 0 && moved > 0
            resultIsFailure = report.summary.failed > 0 && moved == 0
            pendingSheet = nil
            if let appOutcome = report.outcomes.first,
               appOutcome.status == .trashed || appOutcome.status == .purged {
                store.removeStorageApp(atPath: app.path)
            }
            await store.fetchStorageApps()
            await store.fetchStorageVolumes()
        } catch {
            let message = ScanStore.describe(error)
            pendingSheet = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.error = message }
        }
    }

    func dismissError() {
        error = nil
    }

    func clearResult() {
        result = nil
        resultIsPartial = false
        resultIsFailure = false
    }

    private func quitIfNeeded(_ app: InstalledApp) async -> Bool {
        let running = RunningAppIdentity.running(bundleId: app.bundleId, appPath: app.path)
        guard !running.isEmpty else { return true }

        isQuitting = true
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if RunningAppIdentity.running(bundleId: app.bundleId, appPath: app.path).isEmpty {
                isQuitting = false
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        isQuitting = false
        error = L10nText("appsQuitFailed", ["name": app.name])
        return false
    }
}
