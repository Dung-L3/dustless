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

extension ProcessInfo {
    public var executablePath: String {
        Self.executablePath(in: command)
    }

    public static func executablePath(in command: String) -> String {
        let marker = [".app/Contents/MacOS/", ".app/Contents/Resources/"]
            .compactMap { prefix -> (String, Range<String.Index>)? in
                command.range(of: prefix, options: .backwards).map { (prefix, $0) }
            }
            .max { $0.1.lowerBound < $1.1.lowerBound }
        if let (prefix, range) = marker {
            let after = String(command[range.upperBound...])
            let args = after.isEmpty ? nil : (after.range(of: " -") ?? after.range(of: "\t-"))
            if let args {
                return String(after[..<args.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            return after
        }
        if let args = command.range(of: " --") {
            return String(command[..<args.lowerBound])
        }
        let headEnd = command.firstIndex(where: \.isWhitespace) ?? command.endIndex
        let head = String(command[..<headEnd])
        if !head.hasPrefix("/") { return head }
        var at: String.Index? = headEnd
        while let index = at, index < command.endIndex {
            var start = index
            while start < command.endIndex, command[start].isWhitespace { start = command.index(after: start) }
            var end = start
            while end < command.endIndex, !command[end].isWhitespace { end = command.index(after: end) }
            if !command[start..<end].contains("/") {
                return String(command[..<index]).trimmingCharacters(in: .whitespaces)
            }
            at = end
        }
        return command
    }
}

public struct ProcessGroup: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let bundlePath: String?
    public let processes: [ProcessInfo]

    public var bytes: UInt64 { processes.reduce(0) { $0 + $1.mem } }
    public var count: Int { processes.count }

    init(id: String, bundlePath: String?, processes: [ProcessInfo]) {
        let name = (id as NSString).lastPathComponent
        self.id = id
        self.bundlePath = bundlePath
        self.label = name.hasSuffix(".app") ? String(name.dropLast(4)) : id
        self.processes = processes
    }

    fileprivate static func bundlePath(in command: String) -> String? {
        guard let at = command.range(of: ".app/Contents/") else { return nil }
        let name = String(command[..<at.lowerBound])
        guard !name.isEmpty else { return nil }
        let path = name as NSString
        return "\(path.deletingLastPathComponent)/\(path.lastPathComponent).app"
    }
}

extension ProcessGroup {
    public var displayName: String {
        guard bundlePath == nil else { return label }
        let name = (label as NSString).lastPathComponent
        return name.isEmpty ? label : name
    }

    public func matches(_ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        if label.lowercased().contains(needle) { return true }
        if let bundlePath, bundlePath.lowercased().contains(needle) { return true }
        return processes.contains {
            $0.name.lowercased().contains(needle) || "\($0.pid)" == needle
        }
    }

    public func contains(category: Category) -> Bool {
        processes.contains { $0.category == category }
    }
}

extension [ProcessInfo] {
    public func groupedByApp() -> [ProcessGroup] {
        var members: [String: [ProcessInfo]] = [:]
        for process in self {
            let bundle = ProcessGroup.bundlePath(in: process.command)
            members[bundle ?? process.executablePath, default: []].append(process)
        }
        return members
            .map { key, processes in
                ProcessGroup(
                    id: key,
                    bundlePath: key.hasSuffix(".app") ? key : nil,
                    processes: processes.sorted { $0.mem > $1.mem }
                )
            }
            .sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
    }
}

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