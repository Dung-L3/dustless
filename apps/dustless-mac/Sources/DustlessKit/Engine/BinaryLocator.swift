import Foundation

public enum BinaryLocationError: LocalizedError {
    case notFound([URL])
    case notExecutable(URL)
    case notAnEngine(URL, String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let searched):
            let list = searched.map(\.path).joined(separator: "\n")
            return "The dustless engine was not found. Searched:\n\(list)\n\nBuild it with `bun run build`, then run `bun run bundle:mac` to copy it into Dustless.app."
        case .notExecutable(let url):
            return "Found dustless at \(url.path) but it is not executable. Run: chmod +x \(url.path)"
        case .notAnEngine(let url, let reason):
            return "Found dustless at \(url.path) but it is not a usable engine binary: \(reason). Rebuild it with `bun run build`, then run `bun run bundle:mac` to copy it into Dustless.app."
        }
    }

    public var localized: L10nText {
        switch self {
        case .notFound(let searched):
            return L10nText("errNotFound", ["list": searched.map(\.path).joined(separator: ", ")])
        case .notExecutable(let url):
            return L10nText("errNotExecutable", ["path": url.path])
        case .notAnEngine(let url, let reason):
            return L10nText("errGeneric", [
                "detail": "Found dustless at \(url.path) but it is not a usable engine binary: \(reason). Rebuild it with `bun run build`, then run `bun run bundle:mac` to copy it into Dustless.app.",
            ])
        }
    }
}

public struct BinarySearchContext: Sendable {
    public var roots: [URL]
    public var ownExecutable: URL?

    public init(roots: [URL], ownExecutable: URL?) {
        self.roots = roots
        self.ownExecutable = ownExecutable
    }
}

public enum BinaryLocator {
    public static let executableName = "dustless"

    public static var current: BinarySearchContext {
        BinarySearchContext(
            roots: roots(resourceURL: Bundle.main.resourceURL, bundleURL: Bundle.main.bundleURL),
            ownExecutable: Bundle.main.executableURL
        )
    }

    public static func roots(resourceURL: URL?, bundleURL: URL) -> [URL] {
        var roots: [URL] = []
        if let resources = resourceURL {
            roots.append(resources)
            roots.append(resources.appendingPathComponent("bin", isDirectory: true))
        }
        roots.append(bundleURL)
        return roots
    }

    public static func locate() throws -> URL {
        try locate(in: current)
    }

    public static func locate(in context: BinarySearchContext) throws -> URL {
        let candidates = candidates(in: context)
        for candidate in candidates {
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            if isOwnExecutable(candidate, own: context.ownExecutable) { continue }
            guard isRegularFile(candidate) else {
                throw BinaryLocationError.notAnEngine(candidate, "it is not a regular file")
            }
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
                throw BinaryLocationError.notExecutable(candidate)
            }
            guard isExecutableProgram(atPath: candidate.path) else {
                throw BinaryLocationError.notAnEngine(candidate, "it is not an executable program")
            }
            return candidate
        }
        throw BinaryLocationError.notFound(candidates)
    }

    public static func candidates(in context: BinarySearchContext) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for root in context.roots {
            let candidate = root.appendingPathComponent(executableName)
            let key = candidate.resolvingSymlinksInPath().path
            if seen.insert(key).inserted { result.append(candidate) }
        }
        return result
    }

    public static func isOwnExecutable(_ candidate: URL, own: URL?) -> Bool {
        guard let own else { return false }
        if let candidateIdentity = FileIdentity(url: candidate),
           let ownIdentity = FileIdentity(url: own) {
            return candidateIdentity == ownIdentity
        }
        return candidate.resolvingSymlinksInPath() == own.resolvingSymlinksInPath()
    }

    static func isRegularFile(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.type] as? FileAttributeType) == .typeRegular
    }

    static func isExecutableProgram(atPath path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        let magic = [UInt8](head)
        if magic == [0xCF, 0xFA, 0xED, 0xFE]
            || magic == [0xCE, 0xFA, 0xED, 0xFE]
            || magic == [0xCA, 0xFE, 0xBA, 0xBE]
            || magic == [0xCA, 0xFE, 0xBA, 0xBF] {
            return true
        }
        return magic[0] == 0x23 && magic[1] == 0x21
    }
}

struct FileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64

    init?(url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber else { return nil }
        self.device = device.uint64Value
        self.inode = inode.uint64Value
    }
}
