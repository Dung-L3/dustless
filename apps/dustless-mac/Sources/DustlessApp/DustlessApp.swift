import DustlessKit
import SwiftUI

@main
struct DustlessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ScanStore()
    @StateObject private var login = LoginItem()
    @StateObject private var settings = AppSettings()
    @StateObject private var awdl = AwdlControl()

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
        observedWindow?.close()
    }

    deinit {
        if let window = observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
    }
}

/// Environment key for closing the current window.
private struct WindowCloseActionKey: EnvironmentKey {
    static let defaultValue: @Sendable () -> Void = { }
}

extension EnvironmentValues {
    var closeWindow: @Sendable () -> Void {
        get { self[WindowCloseActionKey.self] }
        set { self[WindowCloseActionKey.self] = newValue }
    }
}

/// View modifier that captures the hosting window and injects a `closeWindow`
/// action into the environment. Use `.windowCloseable()` on the root view of
/// a window scene.
struct WindowCloseable: ViewModifier {
    @State private var closeAction: (@Sendable () -> Void)?

    func body(content: Content) -> some View {
        content
            .background(WindowCaptureForClose(closeAction: $closeAction))
            .environment(\.closeWindow, closeAction ?? {})
    }
}

extension View {
    func windowCloseable() -> some View {
        modifier(WindowCloseable())
    }
}

@MainActor
final class WindowCaptureForCloseView: NSView {
    var closeActionBinding: Binding<(@Sendable () -> Void)?>

    init(closeActionBinding: Binding<(@Sendable () -> Void)?>) {
        self.closeActionBinding = closeActionBinding
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }
        closeActionBinding.wrappedValue = { [weak window] in
            window?.close()
        }
    }
}

struct WindowCaptureForClose: NSViewRepresentable {
    @Binding var closeAction: (@Sendable () -> Void)?

    func makeNSView(context: Context) -> NSView {
        WindowCaptureForCloseView(closeActionBinding: $closeAction)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
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
            .windowCloseable()
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
            .windowCloseable()
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
