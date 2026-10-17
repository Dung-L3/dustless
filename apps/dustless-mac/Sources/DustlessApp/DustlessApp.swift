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
        // One window. Memory, Storage and Network used to be three more
        // `Window` scenes, which meant two navigation systems and three
        // click-away panels; they are destinations in this window now.
        //
        // No `.preferredColorScheme` in this file: light/dark is applied once,
        // app-wide, by `AppSettings.applyAppearance()` writing `NSApp.appearance`.
        //
        // The scene modifier was not broken — it does follow a live switch, and it
        // does release when handed `nil` back — but it pins the choice on that
        // scene's window, and the menu-bar popover is AppKit's surface rather than a
        // SwiftUI scene's, so it never got it. `NSApp.appearance` is the one value
        // every window, sheet and AppKit-drawn control reads. See `AppSettings`.
        WindowGroup("Dustless") {
            RootView(store: store, router: router, net: net)
                .environmentObject(store)
                .environmentObject(net)
                .environmentObject(settings)
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
                // ⌘R lives here and nowhere else. `SummaryHeader` used to
                // register the same shortcut with a different disable rule, so
                // which of the two answered the key depended on which module was
                // open — and in Cleanup the two rules disagreed.
                Button(settings.t("rescan")) { Task { await store.rescan() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.isBusy)
            }
            // The Go menu used to switch safety tiers. Those are a selection
            // inside Cleanup now, so the menu goes to the modules instead.
            CommandMenu(settings.t("goMenu")) {
                ForEach(Module.allCases) { module in
                    Button(settings.t(module.titleKey)) { router.select(module) }
                        .keyboardShortcut(module.shortcut)
                }
            }
        }

        Settings {
            SettingsView(settings: settings, login: login, awdl: awdl)
                .environmentObject(settings)
        }

        // A popover, not a menu: `.window` lets the surface carry measurements
        // rather than a list of commands. Its wording comes from `AppSettings` on
        // every render, so it follows the language without a relaunch; its
        // appearance comes from `NSApp`, since this popover is AppKit's window
        // rather than a SwiftUI scene's.
        MenuBarExtra {
            MenuBarContent(store: store, router: router, net: net, awdl: awdl, onOpenWindow: openMainWindow)
                .environmentObject(settings)
        } label: {
            MenuBarLabel()
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

/// Holds the app responsive while a system admin prompt is up, and brings it
/// back once it is done.
///
/// Why this exists: the macOS authorization dialog is owned by another process
/// (SecurityAgent, reached through osascript), so it makes our app inactive and
/// takes key status without ever attaching a sheet to our window. Nothing in
/// SwiftUI sees that, so without the gate the admin prompt reads as a click-away
/// and the window is brought forward while the user is still typing their
/// password. Depth-counted so overlapping prompts cannot release each other's
/// hold.
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
        // outcome — without it the window is on screen but unusable.
        NSApp.activate(ignoringOtherApps: true)
        // Only if that flow is still live: a prompt the user cancelled must not
        // be resurrected by its own release.
        if let window, window.isVisible {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
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
    @ObservedObject var router: AppRouter
    @ObservedObject var net: NetControl

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            ModuleSidebar(store: store, selection: router.module) { module in
                router.select(module)
            }
        } detail: {
            ModuleContent(store: store, router: router, net: net)
        }
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
        // Only the confirmation is a sheet. The result of a finished cleanup is
        // drawn inline by `CleanupResultCard` above the findings list: the
        // deletion is already done and the list behind it shows what is left, so
        // a modal would only ask for a second acknowledgement.
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
