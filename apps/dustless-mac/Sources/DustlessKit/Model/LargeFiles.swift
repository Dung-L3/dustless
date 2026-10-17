import Foundation

public struct LargeFile: Codable, Identifiable, Sendable, Hashable {
    public let path: String
    public let size: UInt64
    public let mtime: Double

    public var id: String { path }

    public var name: String { (path as NSString).lastPathComponent }

    public var modified: Date { Date(timeIntervalSince1970: mtime / 1000) }
}

extension LargeFile {
    public func matches(_ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        return name.lowercased().contains(needle) || path.lowercased().contains(needle)
    }
}