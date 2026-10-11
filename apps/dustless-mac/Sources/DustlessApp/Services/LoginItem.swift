import DustlessKit
import Foundation
import ServiceManagement

enum LoginItemState: Equatable {
    case unknown
    case registered
    case notRegistered
    case unsupported(String)

    var isEnabled: Bool { self == .registered }
}

@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var state: LoginItemState = .unknown
    @Published private(set) var lastError: L10nText?

    private let service = SMAppService.mainApp

    var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func refresh() {
        guard isSupported else {
            state = .unsupported("loginNeedsBundle")
            return
        }
        state = service.status == .enabled ? .registered : .notRegistered
    }

    func setEnabled(_ enabled: Bool) {
        guard isSupported else {
            refresh()
            return
        }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            lastError = nil
        } catch {
            lastError = enabled
                ? L10nText("loginRegisterFailed", ["error": error.localizedDescription])
                : L10nText("loginRemoveFailed", ["error": error.localizedDescription])
        }
        refresh()
    }
}
