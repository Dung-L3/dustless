import AppKit
import DustlessKit
import Foundation

@MainActor
final class ApplicationsControl: ObservableObject {
    @Published var pendingSheet: InstalledApp?
    @Published private(set) var result: UninstallReport?
    @Published private(set) var resultIsPartial = false
    @Published private(set) var workingApp: String?
    @Published private(set) var isQuitting = false
    @Published private(set) var error: L10nText?

    var isWorking: Bool { workingApp != nil }

    func isRunning(_ app: InstalledApp) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleId).isEmpty
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
            resultIsPartial = report.summary.failed > 0
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
    }

    private func quitIfNeeded(_ app: InstalledApp) async -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleId)
        guard !running.isEmpty else { return true }
        let regular = running.filter { $0.activationPolicy == .regular }
        guard !regular.isEmpty,
              regular.contains(where: {
                  $0.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: app.path).standardizedFileURL.path
              }) else {
            error = L10nText("appsQuitFailed", ["name": app.name])
            return false
        }

        isQuitting = true
        regular.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleId).isEmpty {
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
