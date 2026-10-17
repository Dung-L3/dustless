import DustlessKit
import Foundation

@MainActor
final class AwdlControl: ObservableObject {
    static let privilegePath = "/etc/sudoers.d/dustless-awdl"

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

    @discardableResult
    func installPrivilege() async -> Bool {
        guard !busy else { return false }
        busy = true
        AutoCloseGate.shared.begin()
        defer {
            AutoCloseGate.shared.end()
            busy = false
        }
        do {
            let privilege = try await DustlessCLI.resolve().awdlPrivilege()
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("dustless-awdl-\(UUID().uuidString)")
            try privilege.rule.write(to: staging, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: staging) }

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
        AutoCloseGate.shared.begin()
        defer {
            AutoCloseGate.shared.end()
            busy = false
        }
        do {
            try await runAdmin("\(Self.rmTool) -f \(sh(Self.privilegePath))")
            privilegeInstalled = FileManager.default.fileExists(atPath: Self.privilegePath)
            error = nil
        } catch {
            self.error = Self.describe(error)
        }
    }

    private static let installTool = "/usr/bin/install"
    private static let visudoTool = "/usr/sbin/visudo"
    private static let rmTool = "/bin/rm"

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

    private func sh(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func describe(_ error: Error) -> L10nText { ScanStore.describe(error) }
}