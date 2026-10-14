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