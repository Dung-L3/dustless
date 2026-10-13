import Foundation

public struct MemoryReport: Codable, Sendable {
    public let memory: MemoryInfo
    public let processes: [ProcessInfo]
}

public struct MemoryInfo: Codable, Sendable {
    public let total: UInt64
    public let used: UInt64
    public let available: UInt64
    public let free: UInt64
    public let compressed: UInt64
    public let swapTotal: UInt64
    public let swapUsed: UInt64
    public let pressure: Pressure
    public let pressurePercent: Int
}

public enum Pressure: String, Codable, Sendable {
    case normal
    case warn
    case critical
}

public struct ProcessInfo: Codable, Identifiable, Sendable, Hashable {
    public let pid: Int
    public let ppid: Int
    public let name: String
    public let command: String
    public let cpu: Double
    public let mem: UInt64
    public let owner: String
    public let root: Bool
    public let category: Category

    public var id: Int { pid }
}

public enum Category: String, Codable, Sendable {
    case browser
    case editor
    case container
    case lsp
    case other
}

/// Result of a `dustless ram --kill` invocation.
public struct RamKillResult: Codable, Sendable {
    public let ok: Bool
    public let reason: String?
    public let reclaimable: UInt64?
    public let reclaimed: UInt64?

    public init(ok: Bool, reason: String? = nil, reclaimable: UInt64? = nil, reclaimed: UInt64? = nil) {
        self.ok = ok
        self.reason = reason
        self.reclaimable = reclaimable
        self.reclaimed = reclaimed
    }
}
