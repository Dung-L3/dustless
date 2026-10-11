import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var login: LoginItem
    let onOpenWindow: () -> Void

    var body: some View {
        Group {
            if let report = store.report {
                Text("Free: \(ByteFormat.string(report.freeBefore))")
                Text("Reclaimable: \(ByteFormat.string(report.reclaimable))")
                Divider()
                Button(store.phase == .scanning ? "Scanning…" : "Rescan Now") {
                    Task { await store.rescan() }
                }
                .disabled(store.phase == .scanning || store.phase == .resolvingEngine)

                Button("Clean \(store.selectedFindings.count) Items…") {
                    onOpenWindow()
                    store.showingConfirmation = true
                }
                .disabled(!store.canClean)
            } else {
                Text("Dustless")
                if let error = store.engineError {
                    Divider()
                    Text("Engine unavailable")
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not scanned yet")
                    Button("Scan Now") { Task { await store.rescan() } }
                        .disabled(store.phase == .scanning)
                }
            }

            Divider()
            Button("Open Dustless", action: onOpenWindow)

            Toggle("Launch at Login", isOn: Binding(
                get: { login.state.isEnabled },
                set: { login.setEnabled($0) }
            ))
            .disabled(!login.isSupported)

            if let error = login.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            Divider()
            Button("Quit Dustless") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
