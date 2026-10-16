import DustlessKit
import Foundation

/// Drives the Network panel: reads the live network state, runs one operation at
/// a time, and hands the AirDrop block the same control the menu bar and
/// Settings use.
///
/// Every engine call is async and spawns its process off the main actor (the
/// CLI's own dispatch queue, and `Task.detached` behind the admin prompt), so a
/// password dialog the user leaves open never freezes the app.
@MainActor
final class NetControl: ObservableObject {
    @Published private(set) var report: NetReport?
    @Published private(set) var isLoading = false
    /// Why the last state read failed. A refresh that fails keeps the report on
    /// screen — stale numbers beat a blank panel.
    @Published private(set) var loadError: L10nText?
    /// Ids of the operations with a run in flight, so each row's own button is
    /// held while its prompt is up.
    @Published private(set) var running: Set<String> = []
    /// The engine's answer per operation, shown under the row that asked for it.
    @Published private(set) var outcomes: [String: NetOutcome] = [:]
    /// A run that produced no report at all: a cancelled admin prompt, a missing
    /// engine. The per-operation detail cannot carry this.
    @Published private(set) var runError: L10nText?

    let awdl = AwdlControl.shared

    /// One run at a time: two admin prompts asking for a password at once is a
    /// question no one can answer.
    var isBusy: Bool { !running.isEmpty }

    func isRunning(_ op: NetOp) -> Bool { running.contains(op.id) }

    /// The freshest answer for an operation: the run the user just made, or what
    /// the last state read reported for it.
    func outcome(for op: NetOp) -> NetOutcome? {
        outcomes[op.id] ?? report?.outcome(for: op.id)
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        do {
            report = try await DustlessCLI.resolve().net()
        } catch {
            loadError = Self.describe(error)
        }
        isLoading = false
        // The panel draws the AirDrop state too, and this is the instance the
        // window owns — without this the toggle reads "unknown" until the menu
        // bar happens to refresh it.
        await awdl.refresh()
    }

    /// Runs one operation, then re-reads the state so the connection block shows
    /// what the run actually changed.
    func run(_ op: NetOp) async {
        guard !isBusy else { return }
        running.insert(op.id)
        runError = nil
        defer { running.remove(op.id) }
        do {
            // --force: the engine refuses the interface-touching operations while
            // this Mac is on its only route, which is exactly the situation the
            // user opened this panel to fix. The admin prompt is the consent.
            let result = try await DustlessCLI.resolve().runNetOp(op.id, force: true)
            outcomes[op.id] = result.outcome(for: op.id)
            await refresh()
        } catch {
            outcomes[op.id] = nil
            runError = Self.describe(error)
        }
    }

    /// Flips AirDrop, installing the scoped toggle permission first if the user
    /// has not done it yet — the same one-prompt step the menu-bar row performs.
    func setAirDrop(_ on: Bool) async {
        if !awdl.privilegeInstalled {
            guard await awdl.installPrivilege() else { return }
        }
        await awdl.setEnabled(on)
    }

    private static func describe(_ error: Error) -> L10nText { ScanStore.describe(error) }
}