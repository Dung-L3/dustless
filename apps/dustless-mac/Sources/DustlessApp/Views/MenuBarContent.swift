import DustlessKit
import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var store: ScanStore
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
                onOpenWindow()
                Task { await store.fetchMemory() }
                store.showingMemory = true
            }
            Button(settings.t("settingsOpen")) { openSettings() }

            Divider()
            Button(settings.t("quitDustless")) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
