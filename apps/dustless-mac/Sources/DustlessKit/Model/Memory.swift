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

// MARK: - Grouping

extension ProcessInfo {
    /// The executable the engine reported: the first token of `command`, which is
    /// the same split the CLI uses to derive `name`. Empty commands fall back to
    /// that name.
    public var executablePath: String {
        command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? name
    }
}

/// One application and the processes that belong to it.
public struct ProcessGroup: Identifiable, Sendable {
    /// The bundle path (`/Applications/Slack.app`), or the executable path when
    /// the process does not live inside an app bundle.
    public let id: String
    /// The bundle name without `.app`, or the executable path when there is no
    /// bundle — so a bare daemon still says which file it is.
    public let label: String
    /// Non-nil only when a bundle was found, so the view only asks for an icon
    /// when there really is one to show.
    public let bundlePath: String?
    /// Every process in the group, biggest first.
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

    /// The app bundle that owns a command line, or nil when there is none.
    /// Every bundled macOS executable lives at `<App>.app/Contents/MacOS/<exe>`,
    /// so that marker locates the bundle without having to guess where the
    /// executable ends — a bundle path may contain a space. It also keeps
    /// `.apple`, `.xpc` and an argument such as `--out=/tmp/report.app` from
    /// passing as bundles.
    fileprivate static func bundlePath(in command: String) -> String? {
        guard let at = command.range(of: ".app/Contents/") else { return nil }
        let name = String(command[..<at.lowerBound])  // "/Applications/Brave Browser"
        guard !name.isEmpty else { return nil }
        let path = name as NSString
        return "\(path.deletingLastPathComponent)/\(path.lastPathComponent).app"
    }
}

extension [ProcessInfo] {
    /// Group processes by the application that owns them, biggest group first.
    ///
    /// The rule, in one line: the app is the `.app` bundle the executable runs
    /// out of. The outermost bundle wins, which puts Brave's twelve renderer
    /// helpers in one group rather than twelve. No bundle at all (a system
    /// daemon) groups on its executable path, and `ppid` is deliberately
    /// ignored: the process tree reshuffles on every respawn, a bundle does not.
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
            // Ties break on the key so the same report always draws the same order.
            .sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
    }
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
