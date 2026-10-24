import AppKit
import Combine
import DustlessKit
import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var router: AppRouter
    @ObservedObject var net: NetControl
    @ObservedObject var awdl: AwdlControl
    let onOpenWindow: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pendingPrivilege = false

    var body: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.m) {
            header
            MenuBarStatusCard(store: store, net: net)
            actions
            Divider()
            destinations
            Divider()
            airDrop
            Divider()
            footer
        }
        .padding(PanelStyle.Space.m)
        .frame(width: 320)
        .onChange(of: router.module) { _, _ in dismiss() }
        .task { await refreshLive() }
        .awdlPrivilegeConfirm(isPresented: $pendingPrivilege) {
            pendingPrivilege = false
            Task {
                guard await awdl.installPrivilege() else { return }
                await awdl.setEnabled(!awdl.isOn)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow,
                  window !== MainWindowTracker.shared.window else { return }
            Task { await refreshLive() }
        }
    }

    private var header: some View {
        let provenance = settings.provenance(store.report, scannedAt: store.scannedAt, engineFailed: store.engineError != nil)
        return VStack(alignment: .leading, spacing: PanelStyle.Space.xs) {
            HStack(spacing: PanelStyle.Space.s) {
                if let mark = MenuBarIcon.image {
                    Image(nsImage: mark)
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                Text("Dustless")
                    .font(PanelFont.emphasis(.semibold))
                Spacer(minLength: PanelStyle.Space.s)
                refreshButton
            }

            Text(provenance)
                .font(PanelFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(provenance)
                .accessibilityIdentifier("menubar.provenance")

            failure

            if let report = store.report {
                UnscannableNotice(report: report, compact: true, identifier: "menubar.unscannable")
            }
        }
    }

    @ViewBuilder
    private var failure: some View {
        if let error = store.engineError {
            VStack(alignment: .leading, spacing: 2) {
                Label(
                    settings.t(store.report == nil ? "engineUnavailable" : "menuStale"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(PanelFont.caption)
                .foregroundStyle(.orange)

                EngineErrorMessage(text: error, showsPaths: false)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(settings.text(error))
            }
            .accessibilityIdentifier("menubar.failure")
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await refreshLive() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(settings.t("refreshHelp"))
        .accessibilityLabel(settings.t("refresh"))
        .accessibilityIdentifier("menubar.refresh")
    }

    private func leave(_ action: () -> Void) {
        dismiss()
        action()
    }

    private var actions: some View {
        VStack(spacing: PanelStyle.Space.s) {
            if let apply = store.lastApply, !store.isBusy, store.selectedFindings.isEmpty {
                Label(
                    settings.t("menubar.result", [
                        "deleted": ByteFormat.string(apply.deletedBytes),
                        "freed": ByteFormat.string(apply.volumeDelta),
                    ]),
                    systemImage: "checkmark.circle.fill"
                )
                .font(PanelFont.caption)
                .foregroundStyle(.secondary)
                .imageScale(.small)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
                .help(settings.t("menubar.resultHelp"))
                .accessibilityIdentifier("menubar.result")
            }

            if !store.selectedFindings.isEmpty {
                Text(settings.t("selectedLine", [
                    "count": settings.itemCount(store.selectedFindings.count),
                    "size": ByteFormat.string(store.selectedBytes),
                ]))
                .font(PanelFont.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }

            if store.isBusy {
                busyStrip
            } else {
                primaryButton
                if store.report != nil {
                    rescanRow
                }
            }
        }
        .animation(PanelMotion.gated(reduceMotion, PanelMotion.fade), value: store.selectedFindings.isEmpty)
        .animation(PanelMotion.gated(reduceMotion, PanelMotion.crossfade), value: store.report == nil)
        .animation(PanelMotion.gated(reduceMotion, PanelMotion.fade), value: store.isBusy)
    }

    private var busyStrip: some View {
        HStack(spacing: PanelStyle.Space.s) {
            ProgressView()
                .controlSize(.small)
            Text(busyText)
                .font(PanelFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .truncationMode(.tail)
                .help(busyText)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("menubar.busy")
    }

    private var busyText: String {
        store.busyMessage.map { settings.text($0) } ?? settings.t("scanningShort")
    }

    @ViewBuilder
    private var primaryButton: some View {
        if store.report == nil {
            Button {
                Task { await store.rescan() }
            } label: {
                Text(scanLabel).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help(settings.t("rescanHelp"))
            .transition(.opacity)
            .accessibilityIdentifier("menubar.scan")
        } else if !store.selectedFindings.isEmpty {
            Button(action: reviewAndClean) {
                Text(settings.t("reviewAndDelete"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!store.canClean)
            .help(settings.t("reviewAndDeleteHelp"))
            .accessibilityLabel(settings.t("overviewReview", [
                "count": settings.itemCount(store.selectedFindings.count),
                "size": ByteFormat.string(store.selectedBytes),
            ]))
            .transition(.opacity)
            .accessibilityIdentifier("menubar.review")
        } else if !store.safeCleanFindings.isEmpty {
            Button(action: quickClean) {
                Text(settings.t("menubar.cleanSafely", [
                    "items": settings.itemCount(store.safeCleanFindings.count),
                    "size": ByteFormat.string(store.safeCleanBytes),
                ]))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.isBusy || store.phase != .ready)
            .help(settings.t("menubar.cleanSafelyHelp"))
            .accessibilityHint(settings.t("menubar.cleanSafelyHelp"))
            .transition(.opacity)
            .accessibilityIdentifier("menubar.quickClean")
        } else {
            Button {
                leave { router.select(.cleanup) }
            } label: {
                Text(settings.t("menuPickToClean")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help(settings.t("menuPickToClean"))
            .transition(.opacity)
            .accessibilityIdentifier("menubar.pick")
        }
    }

    private var rescanRow: some View {
        Button {
            Task { await store.rescan() }
        } label: {
            Label(
                store.isBusy ? settings.t("scanningShort") : settings.t("rescan"),
                systemImage: "arrow.clockwise"
            )
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(store.isBusy)
        .help(settings.t("rescanHelp"))
        .accessibilityIdentifier("menubar.rescan")
    }

    private var scanLabel: String {
        if store.isBusy { return settings.t("scanningShort") }
        return store.report == nil ? settings.t("scanNow") : settings.t("rescan")
    }

    private func reviewAndClean() {
        leave {
            router.select(.cleanup)
            store.showingConfirmation = true
        }
    }

    private func quickClean() {
        leave {
            store.tierTab = .safe
            store.selectQuickClean()
            router.select(.cleanup)
            store.showingConfirmation = true
        }
    }

    private var destinations: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Module.allCases) { module in
                destinationRow(module)
            }
        }
    }

    private func destinationRow(_ module: Module) -> some View {
        let title = settings.t(module.titleKey)
        return Button {
            leave { router.select(module) }
        } label: {
            HStack(spacing: PanelStyle.Space.s) {
                Image(systemName: module.symbolName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(PanelFont.emphasis())
                Spacer(minLength: PanelStyle.Space.s)
                if module == .cleanup, !store.selectedFindings.isEmpty {
                    Text(settings.itemCount(store.selectedFindings.count))
                        .font(PanelFont.number())
                        .foregroundStyle(.secondary)
                }
                Text(keyEquivalent(module))
                    .font(PanelFont.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, PanelStyle.Space.xs)
            .padding(.horizontal, PanelStyle.Space.s)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("menubar.module.\(module.rawValue)")
    }

    private func keyEquivalent(_ module: Module) -> String {
        let mods = module.shortcut.modifiers
        var glyphs = ""
        if mods.contains(.control) { glyphs += "\u{2303}" }
        if mods.contains(.option) { glyphs += "\u{2325}" }
        if mods.contains(.shift) { glyphs += "\u{21E7}" }
        if mods.contains(.command) { glyphs += "\u{2318}" }
        return glyphs + String(module.shortcut.key.character).uppercased()
    }

    private var airDrop: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
            HStack(spacing: PanelStyle.Space.s) {
                Image(systemName: "airdrop")
                    .font(.system(size: 12))
                    .foregroundStyle(awdl.isOn ? Color.blue : Color.secondary)
                    .frame(width: 18)
                Text(airDropState)
                    .font(PanelFont.emphasis())
                    .lineLimit(1)
                Spacer(minLength: PanelStyle.Space.s)
                airDropButton
            }
            .help(airDropHelp)

            if let error = awdl.error {
                EngineErrorMessage(text: error, showsPaths: false)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(settings.text(error))
            }
        }
    }

    private var airDropState: String {
        switch awdl.state {
        case .on: settings.t("awdlOnShort")
        case .off: settings.t("awdlOffShort")
        default: settings.t("awdlUnknown")
        }
    }

    private var airDropHelp: String {
        switch awdl.state {
        case .on: settings.t("awdlOn")
        case .off: settings.t("awdlOff")
        default: settings.t("awdlUnknown")
        }
    }

    @ViewBuilder
    private var airDropButton: some View {
        if let state = awdl.state, state != .absent {
            Button(awdl.isOn ? settings.t("awdlTurnOff") : settings.t("awdlTurnOn")) {
                Task { await toggleAirDrop() }
            }
            .controlSize(.small)
            .disabled(awdl.busy)
            .help(airDropHelp)
            .accessibilityIdentifier("menubar.awdl.toggle")
        }
    }

    private func toggleAirDrop() async {
        if !awdl.privilegeInstalled {
            pendingPrivilege = true
            return
        }
        await awdl.setEnabled(!awdl.isOn)
    }

    private var footer: some View {
        HStack(spacing: PanelStyle.Space.s) {
            Button {
                leave(onOpenWindow)
            } label: {
                Text(settings.t("openDustless"))
            }
            .controlSize(.small)
            .accessibilityIdentifier("menubar.open")

            Spacer(minLength: PanelStyle.Space.s)

            Button {
                leave { openSettings() }
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(settings.t("settingsOpen"))
            .accessibilityLabel(settings.t("settingsOpen"))
            .accessibilityIdentifier("menubar.settings")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(settings.t("quitDustless"))
            .accessibilityLabel(settings.t("quitDustless"))
            .accessibilityIdentifier("menubar.quit")
        }
    }

    private func refreshLive() async {
        await store.ensureMemory()
        await net.refreshIfStale()
        await store.fetchStorage()
    }
}