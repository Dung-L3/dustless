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
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        state
            .task { await store.ensureMemory() }
    }

    @ViewBuilder
    private var state: some View {
        if store.memoryReport != nil {
            MemoryView()
        } else if store.memoryPhase == .failed {
            PanelStateView(
                kind: .error,
                message: store.memoryError.map { settings.text($0) } ?? settings.t("engineUnavailable"),
                title: settings.t("engineUnavailable"),
                actionTitle: settings.t("retry"),
                action: { Task { await store.fetchMemory() } },
                identifier: "memory.state",
                actionIdentifier: "memory.retry"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.memoryPhase == .loaded {
            PanelStateView(
                kind: .empty,
                message: settings.t("memoryNoProcesses"),
                title: settings.t("memory"),
                identifier: "memory.state"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PanelStateView(
                kind: .loading,
                message: settings.t("busyMemory"),
                identifier: "memory.state"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct NetworkModuleView: View {
    @ObservedObject var net: NetControl

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        state
            .task { await net.refresh() }
    }

    @ViewBuilder
    private var state: some View {
        if net.report != nil {
            NetView(net: net)
        } else if let error = net.loadError {
            PanelStateView(
                kind: .error,
                message: settings.text(error),
                title: settings.t("networkUnavailable"),
                actionTitle: settings.t("retry"),
                action: { Task { await net.refresh() } },
                identifier: "network.state",
                actionIdentifier: "network.retry"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PanelStateView(
                kind: .loading,
                message: settings.t("busyNetwork"),
                identifier: "network.state"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}