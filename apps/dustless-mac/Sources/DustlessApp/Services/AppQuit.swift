import AppKit
import DustlessKit

@MainActor
enum AppQuit {
    struct Target {
        let bundleID: String
        let name: String
        let app: NSRunningApplication
    }

    struct Facts {
        let bundlePath: String?
        let bundleID: String?
        let ownBundleID: String?
        let owners: Set<String>
        let currentUser: String
        let anyRoot: Bool
        let isRunning: Bool
        let policy: NSApplication.ActivationPolicy?
    }

    static func isEligible(_ facts: Facts) -> Bool {
        guard let path = facts.bundlePath, path.hasSuffix(".app") else { return false }
        guard let bundleID = facts.bundleID, !bundleID.isEmpty else { return false }
        guard bundleID != facts.ownBundleID else { return false }
        guard facts.isRunning, facts.policy == .regular else { return false }
        guard !facts.anyRoot else { return false }
        guard !facts.owners.isEmpty, facts.owners.allSatisfy({ $0 == facts.currentUser }) else { return false }
        return true
    }

    static func target(for group: ProcessGroup) -> Target? {
        guard let path = group.bundlePath else { return nil }
        let bundleID = bundleIdentifier(at: path)
        let app = bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
        let facts = Facts(
            bundlePath: path,
            bundleID: bundleID,
            ownBundleID: Bundle.main.bundleIdentifier,
            owners: Set(group.processes.map(\.owner)),
            currentUser: NSUserName(),
            anyRoot: group.processes.contains(where: \.root),
            isRunning: app != nil,
            policy: app?.activationPolicy
        )
        guard isEligible(facts), let bundleID, let app else { return nil }
        return Target(bundleID: bundleID, name: group.label, app: app)
    }

    static func requestQuit(_ target: Target) -> Bool {
        target.app.terminate()
    }

    private static var bundleIDCache: [String: String?] = [:]

    private static func bundleIdentifier(at path: String) -> String? {
        if let cached = bundleIDCache[path] { return cached }
        if bundleIDCache.count > 400 { bundleIDCache.removeAll(keepingCapacity: true) }
        let identifier = Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier
        bundleIDCache[path] = identifier
        return identifier
    }
}
