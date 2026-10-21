import Foundation

public struct VolumeInfo: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let total: UInt64
    public let used: UInt64
    public let free: UInt64

    public init(id: UUID = UUID(), name: String, total: UInt64, used: UInt64, free: UInt64) {
        self.id = id
        self.name = name
        self.total = total
        self.used = used
        self.free = free
    }

    public var usedPercent: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total)
    }
}
