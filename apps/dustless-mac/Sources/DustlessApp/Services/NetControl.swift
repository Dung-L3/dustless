import Combine
import DustlessKit
import Foundation

@MainActor
final class NetControl: ObservableObject {
    static var privilegePath: String { PrivilegePaths.net }

    @Published private(set) var report: NetReport?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: L10nText?
    @Published private(set) var running: Set<String> = []
    @Published private(set) var outcomes: [String: NetOutcome] = [:]
    @Published private(set) var runError: L10nText?
    @Published private(set) var privilegeInstalled = false
    @Published private(set) var privilegeBusy = false
    @Published private(set) var privilegeError: L10nText?

    let awdl = AwdlControl.shared
    private(set) var lastLoadedAt: Date?

    private var cancellables: Set<AnyCancellable> = []

    init() {
        awdl.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var isBusy: Bool { !running.isEmpty }

    func isRunning(_ op: NetOp) -> Bool { running.contains(op.id) }

    func outcome(for op: NetOp) -> NetOutcome? {
        outcomes[op.id] ?? report?.outcome(for: op.id)
    }

    func refresh() async {
        guard !isLoading else { return }
        privilegeInstalled = Self.readPrivilegeInstalled()
        isLoading = true
        loadError = nil
        do {
            report = try await DustlessCLI.resolve().net()
            lastLoadedAt = Date()
        } catch {
            loadError = Self.describe(error)
        }
        isLoading = false
        await awdl.refresh()
    }

    func refreshIfStale(maxAge: TimeInterval = 15) async {
        if let at = lastLoadedAt, report != nil, Date().timeIntervalSince(at) < maxAge { return }
        await refresh()
    }

    func run(_ op: NetOp) async {
        guard !isBusy else { return }
        running.insert(op.id)
        runError = nil
        let installed = Self.readPrivilegeInstalled()
        privilegeInstalled = installed
        let gated = op.isAdvanced && !installed
        if gated { AutoCloseGate.shared.begin() }
        defer {
            if gated { AutoCloseGate.shared.end() }
            running.remove(op.id)
        }
        do {
            let result = try await DustlessCLI.resolve().runNetOp(
                op.id,
                force: true,
                privilegeInstalled: installed
            )
            outcomes[op.id] = result.outcome(for: op.id)
            privilegeError = (result.outcome(for: op.id)?.status == .refused && !installed)
                ? L10nText("netNeedsPermission")
                : nil
            await refresh()
        } catch {
            outcomes[op.id] = nil
            runError = Self.describe(error)
        }
    }

    @discardableResult
    func installPrivilege() async -> Bool {
        guard !privilegeBusy else { return false }
        privilegeBusy = true
        privilegeError = nil
        AutoCloseGate.shared.begin()
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

            try await runAdmin(
                "\(Self.visudoTool) -cf \(sh(staging.path))"
                    + " && \(Self.installTool) -m 0440 -o root -g wheel \(sh(staging.path)) \(sh(privilege.path))"
            )
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
            privilegeError = nil
        } catch {
            privilegeError = Self.describe(error)
        }
    }

    func dismissRunError() { runError = nil }
    func dismissPrivilegeError() { privilegeError = nil }

    private static func readPrivilegeInstalled() -> Bool {
        FileManager.default.fileExists(atPath: privilegePath)
    }

    func setAirDrop(_ on: Bool) async {
        if !awdl.privilegeInstalled {
            guard await awdl.installPrivilege() else { return }
        }
        await awdl.setEnabled(on)
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