import DustlessKit
import SwiftUI

@main
struct DustlessApp: App {
    @StateObject private var store = ScanStore()
    @StateObject private var login = LoginItem()

    var body: some Scene {
        WindowGroup("Dustless") {
            RootView(store: store, login: login)
                .frame(minWidth: 940, minHeight: 560)
                .task {
                    login.refresh()
                    await store.rescan()
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rescan") { Task { await store.rescan() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.phase == .scanning)
            }
        }

        MenuBarExtra {
            MenuBarContent(store: store, login: login) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
        } label: {
            Image(systemName: store.report.map { $0.reclaimable > 0 ? "sparkles" : "checkmark.circle" } ?? "internaldrive")
        }
        .menuBarExtraStyle(.menu)
    }
}

struct RootView: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var login: LoginItem

    var body: some View {
        NavigationSplitView {
            SidebarView(
                store: store,
                login: login,
                onOpenWindow: openWindow,
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

    private func openWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        NSApp.sendAction(#selector(NSDocumentController.newDocument(_:)), to: nil, from: nil)
    }
}
