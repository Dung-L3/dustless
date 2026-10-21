import Foundation

enum PrivilegePaths {
    static var directory: String {
        #if DUSTLESS_UI_TESTING
        guard let path = ProcessInfo.processInfo.environment["DUSTLESS_SUDOERS_DIR"], !path.isEmpty else {
            fatalError("DUSTLESS_SUDOERS_DIR is required in the UI-test app")
        }
        return path
        #else
        return "/etc/sudoers.d"
        #endif
    }

    static var net: String { directory + "/dustless-net" }
    static var awdl: String { directory + "/dustless-awdl" }
}
