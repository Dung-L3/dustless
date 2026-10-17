import DustlessKit
import SwiftUI

/// The detail pane: whichever module the sidebar picked.
///
/// One view owns the switch so the module switch has exactly one animation
/// site. It is a short opacity cross-fade and nothing else — a slide here
/// implied the modules are a stack of pages, which is not what they are.
struct ModuleContent: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var router: AppRouter
    @ObservedObject var net: NetControl

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // No `.id` on the module: the `switch` already builds a fresh
            // module on every change, so re-identifying the chain on top of that
            // only builds the incoming one twice — measured, its body ran twice
            // per switch with the id and once without. The cross-fade is
            // unaffected either way, because a conditional is already one
            // insertion and one removal. State lifetime is unaffected too.
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: router.module)
    }

    @ViewBuilder
    private var content: some View {
        switch router.module {
        case .overview:
            OverviewView(store: store, net: net, router: router)
        case .cleanup:
            VStack(spacing: 0) {
                SummaryHeader(
                    report: store.report,
                    isScanning: store.isBusy
                ) {
                    Task { await store.rescan() }
                }
                DetailView(store: store) { store.showingConfirmation = true }
            }
        case .storage:
            StorageModuleView()
        case .memory:
            MemoryModuleView()
        case .network:
            NetworkModuleView(net: net)
        }
    }
}

/// The Storage module: loads the volume data on appear, then fills the pane.
struct StorageModuleView: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        state
            .task { await store.fetchStorage() }
    }

    @ViewBuilder
    private var state: some View {
        // A refresh re-reads behind the pane, so only a pane that has never read
        // anything blanks out. A failed read wins over everything else.
        if let space = store.diskSpace {
            StorageView(space: space, reclaimable: store.report?.reclaimable)
        } else if store.storagePhase == .failed {
            PanelStateView(
                kind: .error,
                message: store.storageError.map { settings.text($0) } ?? settings.t("engineUnavailable"),
                title: settings.t("engineUnavailable"),
                actionTitle: settings.t("retry"),
                action: { Task { await store.fetchStorage() } }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.storagePhase == .loaded {
            PanelStateView(
                kind: .empty,
                message: settings.t("volumesEmpty"),
                title: settings.t("storage")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PanelStateView(kind: .loading, message: settings.t("busyStorage"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The Memory module: loads the process list on appear, then fills the pane.
struct MemoryModuleView: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        state
            .task { await store.ensureMemory() }
    }

    @ViewBuilder
    private var state: some View {
        // Same shape as the Storage module: keep the last report on screen, and
        // only blank the pane when there is nothing to show and nothing coming.
        if store.memoryReport != nil {
            MemoryView()
        } else if store.memoryPhase == .failed {
            PanelStateView(
                kind: .error,
                message: store.memoryError.map { settings.text($0) } ?? settings.t("engineUnavailable"),
                title: settings.t("engineUnavailable"),
                actionTitle: settings.t("retry"),
                action: { Task { await store.fetchMemory() } }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.memoryPhase == .loaded {
            PanelStateView(
                kind: .empty,
                message: settings.t("memoryNoProcesses"),
                title: settings.t("memory")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PanelStateView(kind: .loading, message: settings.t("busyMemory"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The Network module: reads the live state on appear, then fills the pane.
struct NetworkModuleView: View {
    @ObservedObject var net: NetControl

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        state
            .task { await net.refresh() }
    }

    @ViewBuilder
    private var state: some View {
        // A failed refresh keeps the last report on screen, so only a pane that
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PanelStateView(kind: .loading, message: settings.t("busyNetwork"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
