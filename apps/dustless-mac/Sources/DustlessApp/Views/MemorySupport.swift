import AppKit
import DustlessKit
import SwiftUI

typealias MemProcess = DustlessKit.ProcessInfo
typealias MemCategory = DustlessKit.Category

extension DustlessKit.ProcessInfo {
    var isProtectedMemoryTarget: Bool {
        root || name.lowercased().contains("dustless")
    }
}

@MainActor
enum MemoryIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        if cache.count > 400 { cache.removeAll(keepingCapacity: true) }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}

enum QuitStatus {
    case quit
    case stillOpen
    case requestFailed
}

enum MemCategoryFilter: String, CaseIterable, Identifiable {
    case all
    case browser
    case editor
    case container
    case lsp
    case other

    var id: String { rawValue }

    var titleKey: String? {
        switch self {
        case .all: nil
        case .browser: "categoryBrowser"
        case .editor: "categoryEditor"
        case .container: "categoryContainer"
        case .lsp: "categoryLSP"
        case .other: "categoryOther"
        }
    }

    var category: MemCategory? {
        switch self {
        case .all: nil
        case .browser: .browser
        case .editor: .editor
        case .container: .container
        case .lsp: .lsp
        case .other: .other
        }
    }
}

struct PendingStop {
    let pid: Int
    let name: String
    let force: Bool
    let sigkill: Bool
}
