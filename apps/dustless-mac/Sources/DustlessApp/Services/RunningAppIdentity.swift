import AppKit
import Foundation

enum RunningAppIdentity {
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    static func isSamePath(_ runningPath: String?, _ appPath: String) -> Bool {
        guard let runningPath else { return false }
        return canonical(runningPath) == canonical(appPath)
    }

    static func matches(_ app: NSRunningApplication, appPath: String) -> Bool {
        isSamePath(app.bundleURL?.path, appPath)
    }

    static func matching(_ apps: [NSRunningApplication], appPath: String) -> [NSRunningApplication] {
        apps.filter { matches($0, appPath: appPath) }
    }

    static func running(bundleId: String, appPath: String) -> [NSRunningApplication] {
        matching(NSRunningApplication.runningApplications(withBundleIdentifier: bundleId), appPath: appPath)
    }
}
