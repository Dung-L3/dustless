import AppKit
import DustlessKit
import Testing
@testable import DustlessApp

@Suite("app quit eligibility")
struct AppQuitTests {
    @MainActor
    private func facts(
        bundlePath: String? = "/Applications/Brave Browser.app",
        bundleID: String? = "com.brave.Browser",
        ownBundleID: String? = "dev.dustless.mac",
        owners: Set<String> = ["mac"],
        currentUser: String = "mac",
        anyRoot: Bool = false,
        isRunning: Bool = true,
        policy: NSApplication.ActivationPolicy? = .regular
    ) -> AppQuit.Facts {
        AppQuit.Facts(
            bundlePath: bundlePath,
            bundleID: bundleID,
            ownBundleID: ownBundleID,
            owners: owners,
            currentUser: currentUser,
            anyRoot: anyRoot,
            isRunning: isRunning,
            policy: policy
        )
    }

    @Test @MainActor func aUserFacingAppIsEligible() {
        #expect(AppQuit.isEligible(facts()))
    }

    @Test @MainActor func theDustlessBundleItselfIsRefused() {
        #expect(!AppQuit.isEligible(facts(ownBundleID: "com.brave.Browser")))
    }

    @Test @MainActor func aProcessOwnedByRootOrAnotherUserIsRefused() {
        #expect(!AppQuit.isEligible(facts(anyRoot: true)))
        #expect(!AppQuit.isEligible(facts(owners: ["root"])))
        #expect(!AppQuit.isEligible(facts(owners: ["mac", "someone-else"])))
        #expect(!AppQuit.isEligible(facts(owners: [])))
    }

    @Test @MainActor func onlyARunningRegularApplicationIsEligible() {
        #expect(!AppQuit.isEligible(facts(isRunning: false)))
        #expect(!AppQuit.isEligible(facts(policy: nil)))
        #expect(!AppQuit.isEligible(facts(policy: .accessory)))
        #expect(!AppQuit.isEligible(facts(policy: .prohibited)))
    }

    @Test @MainActor func onlyABundleWithAnIdentifierIsEligible() {
        #expect(!AppQuit.isEligible(facts(bundlePath: nil)))
        #expect(!AppQuit.isEligible(facts(bundlePath: "/usr/libexec/xpcproxy")))
        #expect(!AppQuit.isEligible(facts(bundleID: nil)))
        #expect(!AppQuit.isEligible(facts(bundleID: "")))
    }
}
