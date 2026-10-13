import Foundation

/// An installed .app bundle, as reported by `dustless apps --json`.
public struct InstalledApp: Codable, Identifiable, Sendable, Hashable {
    public let bundleId: String
    public let name: String
    public let path: String
    public let bytes: UInt64
    /// Leftover files/dirs tied to the bundle id (plain paths, as the CLI emits).
    public let relatedPaths: [String]

    public var id: String { path }

    public init(bundleId: String, name: String, path: String, bytes: UInt64, relatedPaths: [String]) {
        self.bundleId = bundleId
        self.name = name
        self.path = path
        self.bytes = bytes
        self.relatedPaths = relatedPaths
    }
}

/// Outcome of uninstalling a single path.
public struct UninstallOutcome: Codable, Sendable, Identifiable, Hashable {
    public let path: String
    public let status: Status
    public let bytes: UInt64
    public let detail: String

    public var id: String { path }

    public init(path: String, status: Status, bytes: UInt64, detail: String) {
        self.path = path
        self.status = status
        self.bytes = bytes
        self.detail = detail
    }

    public enum Status: String, Codable, Sendable, CaseIterable {
        case trashed
        case purged
        case skipped
        case failed
    }
}

/// Full report from `dustless apps --uninstall`.
public struct UninstallReport: Codable, Sendable, Identifiable {
    public let outcomes: [UninstallOutcome]
    public let summary: Summary

    public var id: String { outcomes.map(\.path).joined(separator: "|") }

    public init(outcomes: [UninstallOutcome], summary: Summary) {
        self.outcomes = outcomes
        self.summary = summary
    }

    public struct Summary: Codable, Sendable {
        public let trashed: UInt64
        public let purged: UInt64
        public let skipped: UInt64
        public let failed: UInt64
        public let totalBytes: UInt64

        public init(trashed: UInt64, purged: UInt64, skipped: UInt64, failed: UInt64, totalBytes: UInt64) {
            self.trashed = trashed
            self.purged = purged
            self.skipped = skipped
            self.failed = failed
            self.totalBytes = totalBytes
        }
    }
}
