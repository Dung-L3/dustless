import AppKit
import Combine
import DustlessKit
import SwiftUI

/// The menu-bar popover — the app's second surface, and the one reached without
/// opening the window.
///
/// Presented with `.menuBarExtraStyle(.window)` rather than `.menu`, so it can
/// carry measurements instead of a list of commands: the last scan's provenance,
/// free space, reclaimable bytes, memory pressure and the network interface,
/// then the two actions worth taking without the window and a row per module.
///
/// It is built from the window's own tokens (`PanelStyle`, `PanelFont`,
/// `panelCard`) so the popover and the window read as one product, and it takes
/// its appearance from `NSApp.appearance` — the menu-bar surface is AppKit's,
/// outside every SwiftUI scene, which is the one place a scene-level colour
/// scheme never reached.
///
/// Honesty rules, unchanged from the rest of the app: no score, no ring, no
/// projection. A figure the engine did not measure draws as `—`, a scan that
/// failed says so, and a number from an older report is labelled with its age
/// rather than presented as current.
struct MenuBarContent: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var router: AppRouter
    @ObservedObject var net: NetControl
    @ObservedObject var awdl: AwdlControl
    let onOpenWindow: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: PanelStyle.Space.m) {
            header
            metrics
            actions
            Divider()
            destinations
            Divider()
            airDrop
            Divider()
            footer
        }
        .padding(PanelStyle.Space.m)
        // Wide enough for two stat columns and the button labels, narrow enough to
        // stay a popover rather than a window.
        .frame(width: 320)
        // The Go menu's ⌘1–⌘5 move `router.module` without a click in here, and a
        // `.window` popover only closes on a real click outside — so the keyboard
        // has the same floating-over-the-module-it-just-opened defect `leave`
        // fixes for row clicks, and gets the same cure. Dismissing a popover that
        // is not presented is a no-op, which is what keeps the window's own ⌘1–⌘5
        // (and the second dismiss that follows `leave`) harmless.
        .onChange(of: router.module) { _, _ in dismiss() }
        .task { await refreshLive() }
        // `.task` above fires once: a `.window` popover keeps its content view
        // alive across open/close, so appearing is not an "opened" event and a
        // second open would keep the first open's numbers. The popover window
        // becoming key is the event that actually repeats. Every read behind
        // `refreshLive` is throttled, so the times the main window or a sheet takes
        // key cost nothing.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow,
                  window !== MainWindowTracker.shared.window else { return }
            Task { await refreshLive() }
        }
    }

    // MARK: - Header

    private var header: some View {
        let provenance = settings.provenance(store.report, scannedAt: store.scannedAt)
        return VStack(alignment: .leading, spacing: PanelStyle.Space.xs) {
            HStack(spacing: PanelStyle.Space.s) {
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

            failure
        }
    }

    /// The last read failed. Two different facts hide behind that, and the menu
    /// bar must not conflate them: with a report on screen the numbers above are
    /// from the last good scan and are now stale; with no report at all there are
    /// no numbers to be stale, and the honest statement is that the engine is
    /// unavailable. Either way the engine's own sentence is shown, capped — a
    /// failure the user only discovers by hovering is barely reported.
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

                Text(settings.text(error))
                    .font(PanelFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(settings.text(error))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await refreshLive() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.borderless)
        .help(settings.t("refreshHelp"))
        .accessibilityLabel(settings.t("refresh"))
    }

    // MARK: - Metrics

    /// The live numbers, as two columns. Each is a measurement or a dash: the
    /// reclaimable figure is the last scan's, the free-space figure falls back to
    /// the live volume read when there is no report, memory and network come from
    /// the same reads the window uses.
    private var metrics: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: PanelStyle.Space.m, alignment: .leading),
                GridItem(.flexible(), spacing: PanelStyle.Space.m, alignment: .leading),
            ],
            alignment: .leading,
            spacing: PanelStyle.Space.s
        ) {
            ForEach(stats) { stat in
                PanelStat(label: stat.label, value: stat.value)
                    .help(stat.help ?? stat.label)
            }
        }
        .padding(PanelStyle.Space.m)
        .panelCard()
    }

    private struct Stat: Identifiable {
        let label: String
        let value: String
        var help: String?
        var id: String { label }
    }

    private var stats: [Stat] {
        [
            Stat(
                label: settings.t("freeNow"),
                value: freeSpace,
                help: settings.t("freeNowHelp")
            ),
            Stat(
                label: settings.t("reclaimableMetric"),
                value: store.report.map { ByteFormat.string($0.reclaimable) } ?? "—",
                help: settings.t("reclaimableHelp")
            ),
            Stat(label: settings.t("memoryPressure"), value: memoryValue),
            Stat(label: settings.t("networkTitle"), value: networkValue, help: networkHelp),
        ]
    }

    private var freeSpace: String {
        if let report = store.report { return ByteFormat.string(report.freeBefore) }
        if let disk = store.diskSpace { return ByteFormat.string(disk.available) }
        return "—"
    }

    private var memoryValue: String {
        guard let memory = store.memoryReport?.memory else {
            return store.memoryPhase == .loading ? settings.t("busyMemory") : "—"
        }
        return "\(settings.pressureLabel(memory.pressure)) · \(memory.pressurePercent)%"
    }

    /// Interface and gateway in one cell, the full pair in the hover. Both are
    /// addresses the engine read; a missing one is a dash, not a zero.
    private var networkValue: String {
        guard let report = net.report else {
            return net.isLoading ? settings.t("busyNetwork") : "—"
        }
        return "\(report.iface ?? "—") · \(report.gateway ?? "—")"
    }

    private var networkHelp: String? {
        guard let report = net.report else { return nil }
        return "\(settings.t("networkInterface")): \(report.iface ?? "—") · "
            + "\(settings.t("networkGateway")): \(report.gateway ?? "—")"
    }

    // MARK: - Actions

    /// Navigating away is the one moment the popover has to get out of the way:
    /// everything else here (Scan, Rescan, Refresh, the AirDrop flip) is meant to
    /// stay on screen while its result lands. A `.window` popover only closes on a
    /// real click outside, so without this a row that opens the main window leaves
    /// the popover floating over the module it just opened — the old `.menu` style
    /// closed itself the moment an item was picked.
    ///
    /// `dismiss` is the environment action every presentation gets, and it is the
    /// only one that works here: ordering the panel out or closing it directly
    /// hides the window without telling SwiftUI, whose "is presented" flag then
    /// still reads open — the next click on the status item does nothing and the
    /// one after that reopens. Measured on the built bundle, both ways.
    private func leave(_ action: () -> Void) {
        dismiss()
        action()
    }

    /// The paths that matter, one per state: the scan while there is no report,
    /// and the way into Cleanup once there is. With nothing ticked that way is an
    /// enabled invitation to go pick items — the prominent slot used to hold a
    /// disabled "Nothing selected" button, a control that looked tappable and did
    /// nothing, and a dead end reads as a broken app. With a selection it is
    /// Review & Clean, which opens the confirmation sheet through the router and
    /// never deletes on its own. Rescan sits under either.
    private var actions: some View {
        VStack(spacing: PanelStyle.Space.s) {
            // What the primary button is about to act on, stated above it — but
            // only when there is something to state: "0 selected · 0 B" is noise.
            if !store.selectedFindings.isEmpty {
                Text(settings.t("selectedLine", [
                    "n": "\(store.selectedFindings.count)",
                    "size": ByteFormat.string(store.selectedBytes),
                ]))
                .font(PanelFont.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if store.report == nil {
                Button {
                    Task { await store.rescan() }
                } label: {
                    Text(settings.t("scanNow")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.isBusy)
                .help(settings.t("rescanHelp"))
            } else {
                if store.selectedFindings.isEmpty {
                    // The way in, not the confirmation: with nothing ticked there
                    // is nothing to confirm, and the sheet must stay down.
                    Button {
                        leave { router.select(.cleanup) }
                    } label: {
                        Text(settings.t("menuPickToClean")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help(settings.t("menuPickToClean"))
                } else {
                    Button(action: reviewAndClean) {
                        Text(settings.t("overviewReview", [
                            "n": "\(store.selectedFindings.count)",
                            "size": ByteFormat.string(store.selectedBytes),
                        ]))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!store.canClean)
                    .help(settings.t("reviewAndDeleteHelp"))
                }

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
            }
        }
    }

    /// Cleanup, then the confirmation. `select` brings the window forward too, so
    /// the sheet is raised over a window the user can see.
    private func reviewAndClean() {
        leave {
            router.select(.cleanup)
            store.showingConfirmation = true
        }
    }

    // MARK: - Destinations

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
                // Cleanup is the one destination with a number worth carrying: how
                // many paths are ticked and waiting for its confirmation.
                if module == .cleanup, !store.selectedFindings.isEmpty {
                    Text(settings.t("itemMany", ["n": "\(store.selectedFindings.count)"]))
                        .font(PanelFont.number())
                        .foregroundStyle(.secondary)
                }
                // Real menus right-align the key equivalent and carry no chevron,
                // and the Go menu's ⌘1–⌘5 do fire while this popover is open — so
                // the row advertises the key the menu answers. Drawn from
                // `Module.shortcut` itself, never a parallel map: a hardcoded
                // 1…5 here is exactly the kind of copy that drifts from the
                // registration it describes.
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
    }

    /// The Go-menu shortcut spelled the way macOS spells shortcuts: modifiers in
    /// the system's own order (⌃⌥⇧⌘), then the key. Built from the same
    /// `KeyboardShortcut` value the menu registers, so this text and that menu
    /// cannot disagree.
    private func keyEquivalent(_ module: Module) -> String {
        let mods = module.shortcut.modifiers
        var glyphs = ""
        if mods.contains(.control) { glyphs += "\u{2303}" }
        if mods.contains(.option) { glyphs += "\u{2325}" }
        if mods.contains(.shift) { glyphs += "\u{21E7}" }
        if mods.contains(.command) { glyphs += "\u{2318}" }
        // Menus draw letter equivalents uppercase (⌘R, not ⌘r); `character`
        // keeps the case it was registered with. Digits are unaffected.
        return glyphs + String(module.shortcut.key.character).uppercased()
    }

    // MARK: - AirDrop

    /// The same AWDL control the Network module and Settings drive, in one row.
    /// The first press installs the scoped sudo rule behind one admin prompt;
    /// after that the flip is password-free.
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

            // A failed install or a refused toggle must be visible right here, not
            // only in Settings: otherwise the button silently does nothing.
            if let error = awdl.error {
                Label(settings.text(error), systemImage: "exclamationmark.triangle.fill")
                    .font(PanelFont.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// The full sentence, on the hover: the row only has room for the short form.
    private var airDropHelp: String {
        switch awdl.state {
        case .on: settings.t("awdlOn")
        case .off: settings.t("awdlOff")
        default: settings.t("awdlUnknown")
        }
    }

    @ViewBuilder
    private var airDropButton: some View {
        // An absent radio cannot be toggled; the engine would refuse it and the
        // button would look broken. The state line above still says why.
        if let state = awdl.state, state != .absent {
            Button(awdl.isOn ? settings.t("awdlTurnOff") : settings.t("awdlTurnOn")) {
                Task { await toggleAirDrop() }
            }
            .controlSize(.small)
            .disabled(awdl.busy)
            .help(airDropHelp)
        }
    }

    private func toggleAirDrop() async {
        if !awdl.privilegeInstalled {
            guard await awdl.installPrivilege() else { return }
        }
        await awdl.setEnabled(!awdl.isOn)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: PanelStyle.Space.s) {
            Button {
                leave(onOpenWindow)
            } label: {
                Text(settings.t("openDustless"))
            }
            .controlSize(.small)

            Spacer(minLength: PanelStyle.Space.s)

            Button {
                leave { openSettings() }
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help(settings.t("settingsOpen"))
            .accessibilityLabel(settings.t("settingsOpen"))

            // ⌘Q is the system's own Quit and still works; this is the one-click
            // copy. Unlike the old menu, this popover binds no key equivalents of
            // its own — the ⌘1–⌘5 the rows display belong to the window's Go
            // menu — so there is no bare "q" to swallow a keystroke.
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help(settings.t("quitDustless"))
            .accessibilityLabel(settings.t("quitDustless"))
        }
    }

    // MARK: - Live reads

    /// The cheap reads, not a rescan. A full disk walk is what the Scan button is
    /// for, and merely opening the menu must not start one; the staleness windows
    /// in the store keep a burst of opens from re-reading the same thing. The
    /// network read carries the AirDrop state with it, so the row is live too.
    private func refreshLive() async {
        await store.ensureMemory()
        await net.refreshIfStale()
        await store.fetchStorage()
    }
}
