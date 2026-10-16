import DustlessKit
import Foundation

/// Drives the menu-bar AirDrop (AWDL) toggle: reads the state through the
/// engine, flips it through the engine, and installs or removes the one scoped
/// sudoers rule that makes the flip password-free.
///
/// The rule itself is never written here — the engine prints it
/// (`dustless awdl --print-privilege`) and this only stages it for the admin
/// step, so there is exactly one definition of what is allowed.
@MainActor
final class AwdlControl: ObservableObject {
    /// Mirrors `AWDL_PRIVILEGE_PATH` in `src/core/net/awdl.ts`. Held here only so
    /// the menu can show installed/not-installed without spawning the engine.
    static let privilegePath = "/etc/sudoers.d/dustless-awdl"

    /// One control for the whole app: the menu bar, Settings and the Network
    /// panel all read and write the same live state, so a permission installed
    /// from any of them is not invisible to the others.
    static let shared = AwdlControl()

    @Published private(set) var state: AwdlState?
    @Published private(set) var privilegeInstalled = false
    @Published private(set) var busy = false
    @Published private(set) var error: L10nText?

    var isOn: Bool { state == .on }

    func refresh() async {
        privilegeInstalled = FileManager.default.fileExists(atPath: Self.privilegePath)
        do {
            state = try await DustlessCLI.resolve().awdl().state
            error = nil
        } catch {
            state = nil
            self.error = Self.describe(error)
        }
    }

    func setEnabled(_ on: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let report = try await DustlessCLI.resolve().setAwdl(on: on)
            state = report.state
            error = report.outcome?.status == .refused ? L10nText("awdlNeedsPrivilege") : nil
        } catch {
            self.error = Self.describe(error)
        }
    }

    /// Writes the rule with one admin prompt. Returns true once it is in place.
    @discardableResult
    func installPrivilege() async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let privilege = try await DustlessCLI.resolve().awdlPrivilege()
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("dustless-awdl-\(UUID().uuidString)")
            try privilege.rule.write(to: staging, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: staging) }

            // visudo validates the staged copy BEFORE it can count. Installing
            // first and validating second would leave a malformed file in
            // /etc/sudoers.d/, which sudo reads, and could wedge sudo machine-wide.
            try await runAdmin(
                "\(Self.visudoTool) -cf \(sh(staging.path))"
                    + " && \(Self.installTool) -m 0440 -o root -g wheel \(sh(staging.path)) \(sh(privilege.path))"
            )
            privilegeInstalled = FileManager.default.fileExists(atPath: Self.privilegePath)
            error = privilegeInstalled ? nil : L10nText("awdlInstallFailed")
            return privilegeInstalled
        } catch {
            self.error = Self.describe(error)
            return false
        }
    }

    func removePrivilege() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await runAdmin("\(Self.rmTool) -f \(sh(Self.privilegePath))")
            privilegeInstalled = FileManager.default.fileExists(atPath: Self.privilegePath)
            error = nil
        } catch {
            self.error = Self.describe(error)
        }
    }

    // MARK: - admin

    private static let installTool = "/usr/bin/install"
    private static let visudoTool = "/usr/sbin/visudo"
    private static let rmTool = "/bin/rm"

    /// Run one shell line as root through the standard macOS admin prompt.
    ///
    /// The wait runs off the main actor: the admin password dialog can stay up
    /// for as long as the user takes, and blocking the main actor behind it
    /// would freeze the whole app.
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
