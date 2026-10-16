import Foundation

/// A plain file big enough to be worth a look, as reported by
/// `dustless largefiles --json`.
public struct LargeFile: Codable, Identifiable, Sendable, Hashable {
    public let path: String
    public let size: UInt64
    /// Milliseconds since the epoch, the same unit the scan report uses.
    public let mtime: Double

    public var id: String { path }

    /// The name a person recognises; the full path stays one context-menu away.
    public var name: String { (path as NSString).lastPathComponent }

    public var modified: Date { Date(timeIntervalSince1970: mtime / 1000) }
}

extension LargeFile {
    /// Whether this file answers a search box, by the name a person recognises
    /// or by the folder it sits in. The needle must already be trimmed and
    /// lowercased; empty matches all.
    public func matches(_ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        return name.lowercased().contains(needle) || path.lowercased().contains(needle)
    }
}
