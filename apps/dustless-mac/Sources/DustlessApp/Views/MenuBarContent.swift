import DustlessKit
import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var awdl: AwdlControl
    let onOpenWindow: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let report = store.report {
                Text(settings.t("freeStat", ["amount": ByteFormat.string(report.freeBefore)]))
                Text("\(settings.t("reclaimableMetric")): \(ByteFormat.string(report.reclaimable))")
                Divider()
                Button(store.phase == .scanning ? settings.t("scanningShort") : settings.t("rescan")) {
                    Task { await store.rescan() }
                }
                .disabled(store.phase == .scanning || store.phase == .resolvingEngine)

                Button(settings.t("cleanItemsMenu", ["n": "\(store.selectedFindings.count)"])) {
                    onOpenWindow()
                    store.showingConfirmation = true
                }
                .disabled(!store.canClean)
            } else {
                Text("Dustless")
                if let error = store.engineError {
                    Divider()
                    Text(settings.t("engineUnavailable"))
                    Text(settings.text(error))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text(settings.t("nothingScanned"))
                    Button(settings.t("rescan")) { Task { await store.rescan() } }
                        .disabled(store.phase == .scanning)
                }
            }

            Divider()
            Button(settings.t("openDustless"), action: onOpenWindow)
            Button(settings.t("memory")) {
                openWindow(id: "memory")
            }
            Button(settings.t("storage")) {
                openWindow(id: "storage")
            }
            Button(settings.t("settingsOpen")) { openSettings() }

            Divider()
            Text(settings.t("awdlTitle"))
            awdlRow

            Divider()
            Button(settings.t("quitDustless")) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .task { await awdl.refresh() }
    }

    /// The AirDrop (AWDL) toggle. The first press installs the scoped sudo rule
    /// behind one admin prompt; after that the flip is password-free.
    @ViewBuilder
    private var awdlRow: some View {
        if let state = awdl.state, state != .absent {
            Text(state == .on ? settings.t("awdlOn") : settings.t("awdlOff"))
            Button(awdl.isOn ? settings.t("awdlTurnOff") : settings.t("awdlTurnOn")) {
                Task {
                    if !awdl.privilegeInstalled {
                        guard await awdl.installPrivilege() else { return }
                    }
                    await awdl.setEnabled(!awdl.isOn)
                }
            }
            .disabled(awdl.busy)
        } else {
            Text(settings.t("awdlUnknown"))
        }
    }
}
