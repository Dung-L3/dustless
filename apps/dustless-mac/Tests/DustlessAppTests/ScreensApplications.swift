import AppKit
import DustlessKit
import Foundation
import SwiftUI
import Testing
@testable import DustlessApp

extension Screens {
    static func applications() -> Screen {
        Screen(
            name: "applications",
            width: 900,
            height: 640,
            stable: false,
            make: { language in
                let settings = TestData.settings(language)
                let store = try TestData.store(apps: try TestData.apps())
                return AnyView(
                    ApplicationsView()
                        .environmentObject(settings)
                        .environmentObject(store)
                )
            }
        )
    }

    static func uninstallSheet() -> Screen {
        Screen(
            name: "uninstall-sheet",
            width: 680,
            height: 520,
            stable: true,
            make: { language in
                let settings = TestData.settings(language)
                let app = try #require(try TestData.apps().first)
                return AnyView(
                    ApplicationUninstallSheet(
                        app: app,
                        isRunning: false,
                        isWorking: false,
                        isQuitting: false,
                        onConfirm: { _, _ in },
                        onCancel: {}
                    )
                    .environmentObject(settings)
                )
            }
        )
    }

}
