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
    @StateObject private var router = AppRouter()

    var body: some Scene {
        WindowGroup("Dustless", id: "main") {
            RootView(store: store, router: router, net: net)
                .environmentObject(store)
                .environmentObject(net)
                .environmentObject(settings)
                .frame(minWidth: 940, minHeight: 560)
                .background(WindowCapture())
                .registerWindowOpener()
                .task {
                    login.refresh()
                    await store.rescan()
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(settings.t("openDustless")) { openMainWindow() }
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityIdentifier("menu.openWindow")
            }
            CommandGroup(after: .newItem) {
                Button(settings.t("rescan")) { Task { await store.rescan() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.isBusy)
                    .accessibilityIdentifier("menu.scan")
            }
            CommandMenu(settings.t("goMenu")) {
                ForEach(Module.allCases) { module in
                    Button(settings.t(module.titleKey)) { router.select(module) }
                        .keyboardShortcut(module.shortcut)
                        .accessibilityIdentifier("menu.module.\(module.rawValue)")
                }
            }
        }

        Settings {
            SettingsView(settings: settings, login: login, awdl: awdl)
                .environmentObject(settings)
        }

        MenuBarExtra {
            MenuBarContent(store: store, router: router, net: net, awdl: awdl, onOpenWindow: openMainWindow)
                .environmentObject(settings)
                .registerWindowOpener()
        } label: {
            MenuBarLabel()
                .accessibilityIdentifier("menubar.status")
                .registerWindowOpener()
        }
        .menuBarExtraStyle(.window)
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
final class WindowOpener {
    static let shared = WindowOpener()

    private var action: (() -> Void)?
    private var isOpening = false
    private var pending = false

    func register(_ action: @escaping () -> Void) {
        self.action = action
        if pending {
            pending = false
            open()
        }
    }

    func open() {
        guard !isOpening else { return }
        guard let action else {
            pending = true
            return
        }
        isOpening = true
        action()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.isOpening = false }
    }
}

private struct WindowOpenerRegistration: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            WindowOpener.shared.register { openWindow(id: "main") }
        }
    }
}

extension View {
    func registerWindowOpener() -> some View {
        modifier(WindowOpenerRegistration())
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
    guard let window = MainWindowTracker.shared.window else {
        WindowOpener.shared.open()
        NSApp.activate(ignoringOtherApps: true)
        return
    }
    if window.isMiniaturized { window.deminiaturize(nil) }
    if window.isVisible {
        window.makeKeyAndOrderFront(nil)
    } else {
        WindowOpener.shared.open()
    }
    NSApp.activate(ignoringOtherApps: true)
}

@MainActor
final class MainWindowTracker {
    static let shared = MainWindowTracker()
    var window: NSWindow?
}

final class WindowCaptureView: NSView {
    override func viewDidMoveToWindow() {
        guard let window else { return }
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

@MainActor
final class AutoCloseGate {
    static let shared = AutoCloseGate()

    private var depth = 0
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
        NSApp.activate(ignoringOtherApps: true)
        if let window, window.isVisible {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let visible = NSApp.windows.contains { $0.title == "Dustless" && $0.isVisible }
            if MainWindowTracker.shared.window == nil && !visible {
                openMainWindow()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow() }
        return true
    }
}

struct RootView: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var router: AppRouter
    @ObservedObject var net: NetControl

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 0) {
            ModuleSidebar(store: store, selection: router.module) { module in
                router.select(module)
            }
            .frame(width: 224)
            Divider()
            ModuleContent(store: store, router: router, net: net)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Dustless")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.rescan() }
                } label: {
                    if isScanning {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .frame(width: 12, height: 12)
                    } else {
                        Label(settings.t("rescan"), systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isScanning)
                .help(settings.t("rescanHelp"))
                .accessibilityIdentifier("toolbar.scan")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openSettings()
                } label: {
                    Label(settings.t("settingsOpen"), systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                .help(settings.t("settingsOpen"))
                .accessibilityIdentifier("toolbar.settings")
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
    }

    private var isScanning: Bool { store.isBusy }
}