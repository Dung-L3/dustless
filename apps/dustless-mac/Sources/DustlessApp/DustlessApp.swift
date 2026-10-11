import DustlessKit
import SwiftUI

@main
struct DustlessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ScanStore()
    @StateObject private var login = LoginItem()
    @StateObject private var settings = AppSettings()

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
            SettingsView(settings: settings, login: login)
                .environmentObject(settings)
                .preferredColorScheme(settings.appearance.colorScheme)
        }

        MenuBarExtra {
            MenuBarContent(store: store, onOpenWindow: openMainWindow)
                .environmentObject(settings)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.menu)
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
