import Foundation

public struct DiskSpace: Sendable, Hashable {
    public let volumeName: String?
    public let total: UInt64
    public let used: UInt64
    public let available: UInt64

    public var free: UInt64 { available }

    public init(volumeName: String?, total: UInt64, used: UInt64, available: UInt64) {
        self.volumeName = volumeName
        self.total = total
        self.used = used
        self.available = available
    }

    public static func homeVolume() -> DiskSpace? {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        do {
            let values = try homeURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey])
            guard let total = values.volumeTotalCapacity,
                  let available = values.volumeAvailableCapacity,
                  total > 0, available >= 0 else {
                return nil
            }
            let totalU = UInt64(total)
            let availableU = UInt64(available)
            let used = totalU - availableU
            let name = values.volumeName
            return DiskSpace(volumeName: name, total: totalU, used: used, available: availableU)
        } catch {
            return nil
        }
    }
}