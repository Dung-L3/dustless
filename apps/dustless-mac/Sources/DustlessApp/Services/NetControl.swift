import Combine
import DustlessKit
import Foundation

/// Drives the Network panel: reads the live network state, runs one operation at
/// a time, and hands the AirDrop block the same control the menu bar and
/// Settings use.
///
/// It also owns the panel's one-time "remember this authorization" step: the
/// advanced operations normally escalate through an admin prompt per run, and
/// with the scoped sudo rule in place the engine escalates through `sudo -n`
/// on its own and never prompts. No password is stored anywhere — the rule
/// permits four exact commands and the panel can remove it again.
///
/// Every engine call is async and spawns its process off the main actor (the
/// CLI's own dispatch queue, and `Task.detached` behind the admin prompt), so a
/// password dialog the user leaves open never freezes the app.
@MainActor
final class NetControl: ObservableObject {
    /// Mirrors `NET_PRIVILEGE_PATH` in `src/core/net/privilege.ts`. Held here
    /// only so the panel can show installed/not-installed without spawning the
    /// engine. The rule text itself is never kept here — the engine prints it.
    static let privilegePath = "/etc/sudoers.d/dustless-net"

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
    /// Whether the scoped sudo rule for the advanced operations is installed.
    @Published private(set) var privilegeInstalled = false
    /// An install or remove is in flight. Its own flag rather than `running`:
    /// this holds an admin prompt, which no operation is waiting on.
    @Published private(set) var privilegeBusy = false
    /// Why the install/remove step failed, or why an operation was refused for
    /// want of the rule.
    @Published private(set) var privilegeError: L10nText?

    let awdl = AwdlControl.shared

    private var cancellables: Set<AnyCancellable> = []

    init() {
        // The panel observes this object, not the AirDrop control, so forward
        // its changes: without this the freshly installed permission would not
        // turn the install button into the installed fact until a reopen.
        awdl.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

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
        // Read the installed fact first: an install or remove that just finished
        // has to be on screen before the first row draws, not after a reopen.
        privilegeInstalled = Self.readPrivilegeInstalled()
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
        // Read the rule off disk here rather than trusting the published copy:
        // it was last written by a `refresh()` or an install, and deciding on a
        // stale value is how two SecurityAgent prompts stack up — one for the
        // operation, one for a permission that is already installed.
        let installed = Self.readPrivilegeInstalled()
        privilegeInstalled = installed
        // Only a run that actually reaches the system admin prompt needs the
        // gate: that is an advanced operation with no rule installed. A safe
        // operation, and an advanced one the rule already covers, never leave
        // the app, so gating them would only cost the panel its outside-click
        // close.
        let gated = op.isAdvanced && !installed
        if gated { AutoCloseGate.shared.begin() }
        defer {
            if gated { AutoCloseGate.shared.end() }
            running.remove(op.id)
        }
        do {
            // --force: the engine refuses the interface-touching operations while
            // this Mac is on its only route, which is exactly the situation the
            // user opened this panel to fix. The admin prompt is the consent.
            //
            // With the rule installed the engine runs the step through `sudo -n`
            // and must not be handed a prompt at all, so it is called directly;
            // without it, one osascript-as-root prompt is the only way to root
            // and the operation still has to work.
            let result = try await DustlessCLI.resolve().runNetOp(
                op.id,
                force: true,
                privilegeInstalled: installed
            )
            outcomes[op.id] = result.outcome(for: op.id)
            // A refusal that names the missing permission is not a crash: it is
            // the panel's cue to offer the one-time install step. Every other
            // outcome clears the banner, so a resolved problem stops being
            // reported on every later run.
            privilegeError = (result.outcome(for: op.id)?.status == .refused && !installed)
                ? L10nText("netNeedsPermission")
                : nil
            await refresh()
        } catch {
            outcomes[op.id] = nil
            runError = Self.describe(error)
        }
    }

    /// Installs the scoped sudo rule with one admin prompt. Returns true once it
    /// is in place.
    ///
    /// This is not a password being saved. It is a sudoers file permitting four
    /// exact commands for this account, validated by `visudo` before it lands,
    /// and removable again at any time.
    @discardableResult
    func installPrivilege() async -> Bool {
        guard !privilegeBusy else { return false }
        privilegeBusy = true
        privilegeError = nil
        AutoCloseGate.shared.begin()
        // `defer` so the hold is released on cancel and on throw too — an
        // unreleased gate would leave every panel un-closable.
        defer {
            AutoCloseGate.shared.end()
            privilegeInstalled = Self.readPrivilegeInstalled()
            privilegeBusy = false
        }
        do {
            let privilege = try await DustlessCLI.resolve().netPrivilege()
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("dustless-net-\(UUID().uuidString)")
            try privilege.rule.write(to: staging, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: staging) }

            // visudo validates the staged copy BEFORE it can count. Installing
            // first and validating second would leave a malformed file in
            // /etc/sudoers.d/, which sudo reads, and could wedge sudo
            // machine-wide.
            try await runAdmin(
                "\(Self.visudoTool) -cf \(sh(staging.path))"
                    + " && \(Self.installTool) -m 0440 -o root -g wheel \(sh(staging.path)) \(sh(privilege.path))"
            )
            // Re-read HERE, before the result is decided: the refresh below
            // belongs to the `defer`, and reading the published property from
            // inside the `do` would still see the value from before the install
            // — so a perfectly good install would report itself a failure and
            // return false. Same order as `AwdlControl.installPrivilege`.
            privilegeInstalled = Self.readPrivilegeInstalled()
            privilegeError = privilegeInstalled ? nil : L10nText("netRememberFailed")
            return privilegeInstalled
        } catch {
            privilegeError = Self.describe(error)
            return false
        }
    }

    func removePrivilege() async {
        guard !privilegeBusy else { return }
        privilegeBusy = true
        privilegeError = nil
        AutoCloseGate.shared.begin()
        defer {
            AutoCloseGate.shared.end()
            privilegeInstalled = Self.readPrivilegeInstalled()
            privilegeBusy = false
        }
        do {
            try await runAdmin("\(Self.rmTool) -f \(sh(Self.privilegePath))")
            // The rule is gone: the banner that said why it could not be
            // installed is no longer a fact about anything.
            privilegeError = nil
        } catch {
            privilegeError = Self.describe(error)
        }
    }

    /// Takes down a banner the user has read. The panel draws them pinned, so
    /// without this an answered question stays on screen until the next run.
    func dismissRunError() { runError = nil }
    func dismissPrivilegeError() { privilegeError = nil }

    /// The installed fact, straight off disk. Every decision about the rule —
    /// install, remove, and whether a run may prompt — reads it here rather
    /// than from the published copy, which is only ever a snapshot of it.
    private static func readPrivilegeInstalled() -> Bool {
        FileManager.default.fileExists(atPath: privilegePath)
    }

    /// Flips AirDrop, installing the scoped toggle permission first if the user
    /// has not done it yet — the same one-prompt step the menu-bar row performs.
    func setAirDrop(_ on: Bool) async {
        if !awdl.privilegeInstalled {
            guard await awdl.installPrivilege() else { return }
        }
        await awdl.setEnabled(on)
    }

    // MARK: - admin

    private static let installTool = "/usr/bin/install"
    private static let visudoTool = "/usr/sbin/visudo"
    private static let rmTool = "/bin/rm"

    /// One shell line as root through the standard macOS admin prompt. The wait
    /// runs off the main actor: the dialog can stay up as long as the user
    /// takes, and blocking the main actor behind it would freeze the whole app.
    private func runAdmin(_ shell: String) async throws {
        let literal = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let status = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"\(literal)\" with administrator privileges"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        guard status == 0 else { throw DustlessError.exited(status: status, stderr: "") }
    }

    /// Single-quote a path for /bin/sh. Paths here are constants or a path we
    /// just created, never user input.
    private func sh(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func describe(_ error: Error) -> L10nText { ScanStore.describe(error) }
}