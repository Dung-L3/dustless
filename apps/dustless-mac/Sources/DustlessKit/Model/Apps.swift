import Foundation

public struct RelatedItem: Codable, Identifiable, Sendable, Hashable {
    public let path: String
    public let kind: String?
    public let category: String?
    public let bytes: UInt64?

    public var id: String { path }

    public init(path: String, kind: String? = nil, category: String? = nil, bytes: UInt64? = nil) {
        self.path = path
        self.kind = kind
        self.category = category
        self.bytes = bytes
    }
}

public struct InstalledApp: Codable, Identifiable, Sendable, Hashable {
    public let bundleId: String
    public let name: String
    public let path: String
    public let bytes: UInt64
    public let relatedPaths: [String]
    public let related: [RelatedItem]?
    public let protected: Bool?

    public var id: String { path }

    public var relatedItems: [RelatedItem] {
        related ?? relatedPaths.map { RelatedItem(path: $0) }
    }

    public var isProtected: Bool {
        protected ?? bundleId.hasPrefix("com.apple.")
    }

    public var relatedBytes: UInt64? {
        let items = relatedItems
        guard !items.isEmpty else { return 0 }
        let measured = items.compactMap(\.bytes)
        guard measured.count == items.count else { return nil }
        return measured.reduce(0, +)
    }

    public init(
        bundleId: String,
        name: String,
        path: String,
        bytes: UInt64,
        relatedPaths: [String],
        related: [RelatedItem]? = nil,
        protected: Bool? = nil
    ) {
        self.bundleId = bundleId
        self.name = name
        self.path = path
        self.bytes = bytes
        self.relatedPaths = relatedPaths
        self.related = related
        self.protected = protected
    }
}

extension InstalledApp {
    public func matches(_ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        return name.lowercased().contains(needle)
            || bundleId.lowercased().contains(needle)
            || path.lowercased().contains(needle)
    }
}

public struct UninstallOutcome: Codable, Sendable, Identifiable, Hashable {
    public let path: String
    public let status: Status
    public let bytes: UInt64
    public let detail: Reason?

    public var id: String { path }

    public init(path: String, status: Status, bytes: UInt64, detail: Reason?) {
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