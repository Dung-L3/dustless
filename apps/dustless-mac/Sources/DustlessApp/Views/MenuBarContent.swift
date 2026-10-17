import DustlessKit
import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var router: AppRouter
    @ObservedObject var awdl: AwdlControl
    let onOpenWindow: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if let report = store.report {
                Text(settings.t("freeStat", ["amount": ByteFormat.string(report.freeBefore)]))
                Text("\(settings.t("reclaimableMetric")): \(ByteFormat.string(report.reclaimable))")
                Divider()
                Button(store.phase == .scanning ? settings.t("scanningShort") : settings.t("rescan")) {
                    Task { await store.rescan() }
                }
                .disabled(store.isBusy)

                Button(settings.t("cleanItemsMenu", ["n": "\(store.selectedFindings.count)"])) {
                    router.select(.cleanup)
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
                        // Both busy phases, like every other rescan control: while
                        // the engine is still being located this one used to sit
                        // live and silently do nothing.
                        .disabled(store.isBusy)
                }
            }

            Divider()
            Button(settings.t("openDustless"), action: onOpenWindow)
            // These used to open three separate `Window` scenes; they navigate
            // the one window now.
            Button(settings.t("memory")) {
                router.select(.memory)
            }
            Button(settings.t("storage")) {
                router.select(.storage)
            }
            Button(settings.t("networkTitle")) {
                router.select(.network)
            }
            Button(settings.t("settingsOpen")) { openSettings() }

            Divider()
            Text(settings.t("awdlTitle"))
            awdlRow

            Divider()
            // No bare "q": this menu is open over the whole screen, so any `q`
            // typed anywhere — a search field, a path — terminated the app. ⌘Q
            // is the system's own Quit and needs no second copy.
            Button(settings.t("quitDustless")) { NSApp.terminate(nil) }
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

        // A failed install or a refused toggle must be visible right here, not
        // only in Settings: otherwise the menu item silently does nothing.
        if let error = awdl.error {
            Label(settings.text(error), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        }
    }
}
