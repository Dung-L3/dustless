import SwiftUI

/// The destinations the one window navigates between.
///
/// Memory, Storage and Network used to be three `Window` scenes opened from the
/// toolbar and the menu bar, so the app had two navigation systems that could
/// disagree about where the user was. They are modules now: one window, one
/// sidebar, and this list is the whole of the navigation.
enum Module: String, CaseIterable, Identifiable, Hashable {
    case overview
    case cleanup
    case storage
    case memory
    case network

    var id: String { rawValue }

    /// i18n key for the sidebar label and the Go menu.
    var titleKey: String {
        switch self {
        case .overview: "overviewTitle"
        case .cleanup: "cleanupModule"
        case .storage: "storage"
        case .memory: "memory"
        case .network: "networkTitle"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .cleanup: "sparkles"
        case .storage: "internaldrive"
        case .memory: "memorychip"
        case .network: "network"
        }
    }

    /// The Go menu owns these now. The tier shortcuts the old menu carried are
    /// gone with it: tiers are a selection inside Cleanup, not a destination.
    var shortcut: KeyboardShortcut {
        switch self {
        case .overview: KeyboardShortcut("1", modifiers: .command)
        case .cleanup: KeyboardShortcut("2", modifiers: .command)
        case .storage: KeyboardShortcut("3", modifiers: .command)
        case .memory: KeyboardShortcut("4", modifiers: .command)
        case .network: KeyboardShortcut("5", modifiers: .command)
        }
    }
}

/// Which module the detail pane shows. One value, one truth: the sidebar, the Go
/// menu, the menu bar and the Overview rows all move through here, so a module
/// can never be "open" in one place and hidden in another.
@MainActor
final class AppRouter: ObservableObject {
    @Published var module: Module = .overview

    /// Selecting a module from outside the window (menu bar, Go menu, an
    /// Overview row) is a request to *show* it, so the window comes forward too.
    func select(_ module: Module) {
        self.module = module
        // Only when the window is not already in front. The sidebar selects on
        // every click, and re-activating a key window would pull focus out of
        // the search field the user is typing in.
        if MainWindowTracker.shared.window?.isKeyWindow != true {
            openMainWindow()
        }
    }
}
