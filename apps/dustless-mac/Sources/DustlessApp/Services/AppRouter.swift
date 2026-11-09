import AppKit
import SwiftUI

enum Module: String, CaseIterable, Identifiable, Hashable {
    case overview
    case cleanup
    case storage
    case applications
    case memory
    case network

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .overview: "overviewTitle"
        case .cleanup: "cleanupModule"
        case .storage: "storage"
        case .applications: "appsTitle"
        case .memory: "memory"
        case .network: "networkTitle"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .cleanup: "sparkles"
        case .storage: "internaldrive"
        case .applications: "square.stack.3d.up"
        case .memory: "memorychip"
        case .network: "network"
        }
    }

    var shortcut: KeyboardShortcut {
        switch self {
        case .overview: KeyboardShortcut("1", modifiers: .command)
        case .cleanup: KeyboardShortcut("2", modifiers: .command)
        case .storage: KeyboardShortcut("3", modifiers: .command)
        case .applications: KeyboardShortcut("4", modifiers: .command)
        case .memory: KeyboardShortcut("5", modifiers: .command)
        case .network: KeyboardShortcut("6", modifiers: .command)
        }
    }

    var group: ModuleGroup {
        switch self {
        case .overview, .cleanup, .storage, .applications: .workspace
        case .memory, .network: .system
        }
    }
}

enum ModuleGroup: CaseIterable {
    case workspace
    case system

    var titleKey: String {
        switch self {
        case .workspace: "workspace"
        case .system: "systemGroup"
        }
    }
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var module: Module = .overview

    func select(_ module: Module) {
        self.module = module
        if MainWindowTracker.shared.window?.isKeyWindow != true {
            openMainWindow()
        }
    }
}