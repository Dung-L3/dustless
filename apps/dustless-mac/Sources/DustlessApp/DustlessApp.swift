import DustlessKit
import SwiftUI

@main
struct DustlessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ScanStore()
    @StateObject private var login = LoginItem()
    @StateObject private var settings = AppSettings()
    @StateObject private var awdl = AwdlControl.shared
    @StateObject private var net = NetControl()

    var body: some Scene {
        WindowGroup("Dustless") {
            RootView(store: store)
                .environmentObject(settings)
                .preferredColorScheme(settings.appearance.colorScheme)
                .frame(minWidth: 940, minHeight: 560)
                .background(WindowCapture())
                .task {
                    login.refresh()
                    await store.rescan()
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button(settings.t("rescan")) { Task { await store.rescan() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.phase == .scanning)
            }
            CommandMenu(settings.t("goMenu")) {
                ForEach(TierTab.allCases) { tab in
                    Button(settings.tabTitle(tab)) { store.tierTab = tab }
                        .keyboardShortcut(tab.shortcut)
                }
            }
        }

        Settings {
            SettingsView(settings: settings, login: login, awdl: awdl)
                .environmentObject(settings)
                .preferredColorScheme(settings.appearance.colorScheme)
        }

        MenuBarExtra {
            MenuBarContent(store: store, awdl: awdl, onOpenWindow: openMainWindow)
                .environmentObject(settings)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.menu)

        Window(settings.t("memory"), id: "memory") {
            MemoryWindowContent()
                .environmentObject(store)
                .environmentObject(settings)
        }
        .defaultSize(width: 700, height: 660)

        Window(settings.t("storage"), id: "storage") {
            StorageWindowContent()
                .environmentObject(store)
                .environmentObject(settings)
        }
        .defaultSize(width: 620, height: 620)

        Window(settings.t("networkTitle"), id: "network") {
            NetWindowContent()
                .environmentObject(net)
                .environmentObject(settings)
        }
        .defaultSize(width: 700, height: 660)
    }
}

struct MenuBarLabel: View {
    var body: some View {
        if let image = MenuBarIcon.image {
            Image(nsImage: image)
        } else {
            Image(systemName: "leaf.fill")
        }
    }
}

@MainActor
enum MenuBarIcon {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Dustless"
        return image
    }()
}

@MainActor
func openMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    if let window = MainWindowTracker.shared.window {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    } else {
        NSApp.sendAction(#selector(NSDocumentController.newDocument(_:)), to: nil, from: nil)
    }
    NSApp.activate(ignoringOtherApps: true)
}

@MainActor
final class MainWindowTracker {
    static let shared = MainWindowTracker()
    weak var window: NSWindow?
}

final class WindowCaptureView: NSView {
    override func viewDidMoveToWindow() {
        MainWindowTracker.shared.window = window
    }
}

struct WindowCapture: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowCaptureView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            MainWindowTracker.shared.window = window
        }
    }
}

/// Holds the panel open while a system admin password prompt is up, and brings
/// the app back once it is done.
///
/// Why this exists: the sheet/modal guard in `CloseOnResignKeyView` cannot see
/// this case. The macOS authorization dialog is owned by another process
/// (SecurityAgent, reached through osascript), so it makes our app inactive and
/// takes key status from the panel without ever attaching a sheet to it. The
/// panel then closed under the user's own prompt and the window was simply
/// gone. Depth-counted so overlapping prompts cannot release each other's hold.
@MainActor
final class AutoCloseGate {
    static let shared = AutoCloseGate()

    private var depth = 0
    /// The window that was frontmost when the first prompt went up — the one to
    /// hand focus back to.
    private weak var pendingWindow: NSWindow?

    var isActive: Bool { depth > 0 }

    func begin() {
        if depth == 0 {
            let front = NSApp.keyWindow ?? NSApp.mainWindow
            pendingWindow = (front?.isVisible ?? false) ? front : nil
        }
        depth += 1
    }

    func end() {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0 else { return }
        let window = pendingWindow
        pendingWindow = nil
        // The prompt belongs to us, so coming back to us is the expected
        // outcome — without it the panel is on screen but unusable.
        NSApp.activate(ignoringOtherApps: true)
        // Only if that flow is still live: a panel the user closed while typing
        // their password must not be resurrected.
        if let window, window.isVisible {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// Closes a window when it resigns key status, i.e. when the user clicks
/// outside it (another window of this app, or another app).
struct CloseOnResignKey: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        CloseOnResignKeyView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
final class CloseOnResignKeyView: NSView {
    private weak var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // SwiftUI calls updateNSView before the view is in a window, so attach
        // here instead — this is the only place the window is guaranteed.
        guard let window, observedWindow !== window else { return }
        if let old = observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: old)
        }
        observedWindow = window
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey(_:)), name: NSWindow.didResignKeyNotification, object: window)
        // The window must be key for resign-key to fire, so make it so.
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard let window = observedWindow else { return }
        // A sheet or alert presented from this window takes key status away from
        // it, so resign-key also fires the moment a confirmation opens. Closing
        // here tore the panel down under its own dialog, which read as a freeze.
        // Only a genuine click-away — another app, the desktop, a sibling window
        // with no child dialog — may close the panel.
        guard window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        // The system admin prompt belongs to another process, so neither check
        // above sees it; it must not read as a click-away either.
        guard !AutoCloseGate.shared.isActive else { return }
        window.close()
    }

    deinit {
        if let window = observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow() }
        return true
    }
}

struct RootView: View {
    @ObservedObject var store: ScanStore

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView(
                store: store,
                onClean: { store.showingConfirmation = true }
            )
        } detail: {
            VStack(spacing: 0) {
                SummaryHeader(
                    report: store.report,
                    isScanning: store.phase == .scanning || store.phase == .resolvingEngine
                ) {
                    Task { await store.rescan() }
                }
                DetailView(store: store) { store.showingConfirmation = true }
            }
        }
        .navigationTitle("Dustless")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: "memory")
                } label: {
                    Label(settings.t("memory"), systemImage: "memorychip")
                }
                .help(settings.t("memory"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: "storage")
                } label: {
                    Label(settings.t("storage"), systemImage: "internaldrive")
                }
                .help(settings.t("storage"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: "network")
                } label: {
                    Label(settings.t("networkTitle"), systemImage: "network")
                }
                .help(settings.t("networkTitle"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openSettings()
                } label: {
                    Label(settings.t("settingsOpen"), systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                .help(settings.t("settingsOpen"))
            }
        }
        .sheet(isPresented: $store.showingConfirmation) {
            ConfirmDeleteSheet(
                findings: store.selectedFindings,
                totalBytes: store.selectedBytes,
                onCancel: { store.showingConfirmation = false },
                onConfirm: { Task { await store.clean() } }
            )
        }
        .sheet(isPresented: $store.showingApplyResult) {
            if let report = store.lastApply {
                ApplyResultSheet(report: report) { store.showingApplyResult = false }
            }
        }
    }
}

/// Content for the Memory window — loads data on appear and includes outside-click close.
struct MemoryWindowContent: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        state
            .background(CloseOnResignKey())
            .task {
                await store.fetchMemory()
            }
    }

    @ViewBuilder
    private var state: some View {
        switch store.memoryPhase {
        case .idle, .loading:
            // A refresh re-reads behind the panel; only the first load blanks it.
            if store.memoryReport != nil {
                MemoryView()
            } else {
                PanelStateView(kind: .loading, message: settings.t("busyMemory"))
                    .frame(width: 640, height: 360)
            }
        case .loaded:
            if store.memoryReport != nil {
                MemoryView()
            } else {
                PanelStateView(
                    kind: .empty,
                    message: settings.t("memoryNoProcesses"),
                    title: settings.t("memory")
                )
                .frame(width: 640, height: 360)
            }
        case .failed:
            PanelStateView(
                kind: .error,
                message: store.memoryError.map { settings.text($0) } ?? settings.t("engineUnavailable"),
                title: settings.t("engineUnavailable"),
                actionTitle: settings.t("retry"),
                action: { Task { await store.fetchMemory() } }
            )
            .frame(width: 640, height: 360)
        }
    }
}

/// Content for the Storage window — loads data on appear and includes outside-click close.
struct StorageWindowContent: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        state
            .background(CloseOnResignKey())
            .task {
                await store.fetchStorage()
            }
    }

    @ViewBuilder
    private var state: some View {
        switch store.storagePhase {
        case .idle, .loading:
            if let space = store.diskSpace {
                StorageView(space: space, reclaimable: store.report?.reclaimable)
            } else {
                PanelStateView(kind: .loading, message: settings.t("busyStorage"))
                    .frame(width: 660, height: 360)
            }
        case .loaded:
            if let space = store.diskSpace {
                StorageView(space: space, reclaimable: store.report?.reclaimable)
            } else {
                PanelStateView(
                    kind: .empty,
                    message: settings.t("volumesEmpty"),
                    title: settings.t("storage")
                )
                .frame(width: 660, height: 360)
            }
        case .failed:
            PanelStateView(
                kind: .error,
                message: store.storageError.map { settings.text($0) } ?? settings.t("engineUnavailable"),
                title: settings.t("engineUnavailable"),
                actionTitle: settings.t("retry"),
                action: { Task { await store.fetchStorage() } }
            )
            .frame(width: 660, height: 360)
        }
    }
}

/// Content for the Network window — loads data on appear and includes outside-click close.
struct NetWindowContent: View {
    @EnvironmentObject private var net: NetControl
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        state
            .background(CloseOnResignKey())
            .task {
                await net.refresh()
            }
    }

    @ViewBuilder
    private var state: some View {
        // A failed refresh keeps the last report on screen, so only a window that
        // has never read the state blanks out and offers a retry.
        if net.report != nil {
            NetView(net: net)
        } else if let error = net.loadError {
            PanelStateView(
                kind: .error,
                message: settings.text(error),
                title: settings.t("networkUnavailable"),
                actionTitle: settings.t("retry"),
                action: { Task { await net.refresh() } }
            )
            .frame(width: 640, height: 360)
        } else {
            PanelStateView(kind: .loading, message: settings.t("busyNetwork"))
                .frame(width: 640, height: 360)
        }
    }
}
