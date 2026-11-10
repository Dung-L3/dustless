import AppKit
import DustlessKit
import Foundation

struct ApplicationRetry: Equatable {
    let app: InstalledApp
    let relatedPaths: [String]
    let purge: Bool
}

@MainActor
final class ApplicationsControl: ObservableObject {
    @Published var pendingSheet: InstalledApp?
    @Published private(set) var result: UninstallReport?
    @Published private(set) var resultIsPartial = false
    @Published private(set) var resultIsFailure = false
    @Published private(set) var retry: ApplicationRetry?
    @Published private(set) var workingApp: String?
    @Published private(set) var isQuitting = false
    @Published private(set) var error: L10nText?

    private var resultIsRetrySuccess = false
    private var resultAppMoved = false
    private var resultIncludedRelated = false
    private var resultUnselectedRelated = false
    private var resultHasRelated = false

    var isWorking: Bool { workingApp != nil }

    var resultTitleKey: String {
        if resultIsRetrySuccess { return "appsRetrySucceeded" }
        if resultIsFailure { return "appsUninstallFailed" }
        if resultIsPartial { return "appsPartialTitle" }
        if resultAppMoved, !resultHasRelated { return "appsUninstalled" }
        if resultAppMoved && (resultUnselectedRelated || !resultIncludedRelated) {
            return "appsApplicationRemovedTitle"
        }
        return "appsUninstalled"
    }

    var resultMessage: L10nText? {
        guard result != nil, !resultIsPartial, !resultIsFailure else { return nil }
        if resultIsRetrySuccess { return L10nText("appsSelectedData") }
        if resultAppMoved, !resultHasRelated { return nil }
        if resultAppMoved && !resultIncludedRelated { return L10nText("appsApplicationOnly") }
        if resultAppMoved && resultUnselectedRelated { return L10nText("appsUnselectedRelatedKept") }
        return L10nText("appsSelectedData")
    }

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
        relatedPaths: [String],
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
            await fail(message: error)
            return
        }
        guard RunningAppIdentity.running(bundleId: app.bundleId, appPath: app.path).isEmpty else {
            await fail(message: L10nText("appsQuitFailed", ["name": app.name]))
            return
        }

        guard FileManager.default.fileExists(atPath: app.path),
              Bundle(url: URL(fileURLWithPath: app.path))?.bundleIdentifier == app.bundleId else {
            await fail(message: L10nText("appsTargetChanged"))
            return
        }

        do {
            let cli = try DustlessCLI.resolve()
            let report = try await cli.uninstallApp(
                path: app.path,
                purge: purge,
                relatedPaths: relatedPaths
            )
            apply(
                report,
                app: app,
                relatedPaths: relatedPaths,
                purge: purge,
                retrySuccess: false,
                store: store
            )
            await store.fetchStorageApps()
            await store.fetchStorageVolumes()
        } catch {
            await fail(message: ScanStore.describe(error))
        }
    }

    func retryRemaining(store: ScanStore) async {
        guard !isWorking, let retry else { return }
        workingApp = retry.app.path
        error = nil
        isQuitting = false
        defer { workingApp = nil }

        do {
            let cli = try DustlessCLI.resolve()
            let report = try await cli.uninstallRelated(
                bundleId: retry.app.bundleId,
                appPath: retry.app.path,
                relatedPaths: retry.relatedPaths,
                purge: retry.purge
            )
            apply(
                report,
                app: retry.app,
                relatedPaths: retry.relatedPaths,
                purge: retry.purge,
                retrySuccess: report.summary.failed == 0,
                store: store
            )
            await store.fetchStorageApps()
        } catch {
            await fail(message: ScanStore.describe(error))
        }
    }

    func dismissError() {
        error = nil
    }

    func clearResult() {
        result = nil
        resultIsPartial = false
        resultIsFailure = false
        resultIsRetrySuccess = false
        resultAppMoved = false
        resultIncludedRelated = false
        resultUnselectedRelated = false
        resultHasRelated = false
    }

    func dismissRetry() {
        retry = nil
        clearResult()
    }

    private func apply(
        _ report: UninstallReport,
        app: InstalledApp,
        relatedPaths: [String],
        purge: Bool,
        retrySuccess: Bool,
        store: ScanStore
    ) {
        result = report
        let moved = report.summary.trashed + report.summary.purged
        let failed = report.summary.failed
        resultIsPartial = failed > 0 && moved > 0
        resultIsFailure = failed > 0 && moved == 0
        resultIsRetrySuccess = retrySuccess
        resultIncludedRelated = !relatedPaths.isEmpty
        resultHasRelated = !app.relatedItems.isEmpty
        let selected = Set(relatedPaths)
        resultUnselectedRelated = app.relatedItems.contains { !selected.contains($0.path) }
        pendingSheet = nil

        let appOutcome = report.outcomes.first {
            RunningAppIdentity.isSamePath($0.path, app.path)
        }
        resultAppMoved = appOutcome?.status == .trashed || appOutcome?.status == .purged

        if resultAppMoved {
            store.removeStorageApp(atPath: app.path)
        }

        let failedRelated = report.outcomes
            .filter { $0.status == .failed && !RunningAppIdentity.isSamePath($0.path, app.path) }
            .map(\.path)
        if resultAppMoved, !failedRelated.isEmpty {
            retry = ApplicationRetry(app: app, relatedPaths: failedRelated, purge: purge)
        } else {
            retry = nil
        }
    }

    private func fail(message: L10nText?) async {
        pendingSheet = nil
        error = nil
        try? await Task.sleep(nanoseconds: 300_000_000)
        error = message
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
