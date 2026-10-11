import Foundation

public enum BinaryLocationError: LocalizedError {
    case notFound([URL])
    case notExecutable(URL)

    public var errorDescription: String? {
        switch self {
        case .notFound(let searched):
            let list = searched.map(\.path).joined(separator: "\n")
            return "The dustless engine was not found. Searched:\n\(list)\n\nBuild it with `bun run build`, then re-run scripts/bundle.sh to copy it into Dustless.app."
        case .notExecutable(let url):
            return "Found dustless at \(url.path) but it is not executable. Run: chmod +x \(url.path)"
        }
    }

    /// Translatable form of `errorDescription` for the UI.
    public var localized: L10nText {
        switch self {
        case .notFound(let searched):
            return L10nText("errNotFound", ["list": searched.map(\.path).joined(separator: ", ")])
        case .notExecutable(let url):
            return L10nText("errNotExecutable", ["path": url.path])
        }
    }
}

public enum BinaryLocator {
    public static let executableName = "dustless"

    private static var candidateRoots: [URL] {
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL {
            roots.append(resources)
            roots.append(resources.appendingPathComponent("bin", isDirectory: true))
        }
        roots.append(Bundle.main.bundleURL)
        roots.append(Bundle.main.executableURL?.deletingLastPathComponent() ?? Bundle.main.bundleURL)
        return roots
    }

    public static func locate() throws -> URL {
        let roots = candidateRoots
        let candidates = roots.map { $0.appendingPathComponent(executableName) }
        guard let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw BinaryLocationError.notFound(candidates)
        }
        guard FileManager.default.isExecutableFile(atPath: existing.path) else {
            throw BinaryLocationError.notExecutable(existing)
        }
        return existing
    }
}
