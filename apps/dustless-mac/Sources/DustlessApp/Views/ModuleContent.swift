import DustlessKit
import SwiftUI

struct ModuleContent: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var router: AppRouter
    @ObservedObject var net: NetControl

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
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
                    tier: store.tierTab,
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

struct StorageModuleView: View {
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        state
            .task { await store.fetchStorage() }
    }

    @ViewBuilder
    private var state: some View {
        if let space = store.diskSpace {
            StorageView(space: space, reclaimable: store.report?.reclaimable)
        } else if store.storagePhase == .failed {
            PanelStateView(
                kind: .error,
                message: store.storageError.map { settings.text($0) } ?? settings.t("engineUnavailable"),
                error: store.storageError,
                title: settings.t("engineUnavailable"),
                actionTitle: settings.t("retry"),
                action: { Task { await store.fetchStorage() } },
                identifier: "storage.state",
                actionIdentifier: "storage.retry"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.storagePhase == .loaded {
            PanelStateView(
                kind: .empty,
                message: settings.t("volumesEmpty"),
                title: settings.t("storage"),
                identifier: "storage.state"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PanelStateView(
                kind: .loading,
                message: settings.t("busyStorage"),
                identifier: "storage.state"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct MemoryModuleView: View {
    @EnvironmentObject private var store: ScanStore

    var body: some View {
        MemoryView()
            .task { await store.ensureMemory() }
    }
}

struct NetworkModuleView: View {
    @ObservedObject var net: NetControl

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NetView(net: net)
            .task { await net.refresh() }
    }
}
