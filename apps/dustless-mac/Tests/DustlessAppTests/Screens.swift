import AppKit
import DustlessKit
import Foundation
import SwiftUI
import Testing
@testable import DustlessApp

@MainActor
enum Screens {
    struct Screen {
        let name: String
        let width: CGFloat
        let height: CGFloat
        let stable: Bool
        let make: (Lang) throws -> AnyView
    }

    static func all() throws -> [Screen] {
        [
            overview(),
            cleanup(),
            cleanupList(),
            confirmSheet(),
            storage(),
            storageList(),
            memory(),
            network(),
            menuBar(),
            settings(),
            unscannable(),
            engineError(),
            engineErrorMessage(),
            uninstallSheet(),
            trashSheet(),
            cleanupResult(),
            tierBadges(),
            controls()
        ]
    }

    static func stable() throws -> [Screen] {
        try all().filter(\.stable)
    }

    private static func overview() -> Screen {
        Screen(
            name: "overview",
            width: 900,
            height: 640,
            stable: false,
            make: { language in
                let settings = TestData.settings(language)
                let store = try TestData.store(
                    memory: try TestData.memoryReport(),
                    apps: try TestData.apps(),
                    files: try TestData.largeFiles()
                )
                return AnyView(
                    OverviewView(store: store, net: NetControl(), router: AppRouter())
                        .environmentObject(settings)
                        .environmentObject(store)
                )
            }
        )
    }

    private static func cleanup() -> Screen {
        Screen(
            name: "cleanup",
            width: 900,
            height: 640,
            stable: false,
            make: { language in
                let settings = TestData.settings(language)
                let store = try TestData.store()
                let report = try #require(store.report)
                return AnyView(
                    VStack(spacing: 0) {
                        SummaryHeader(report: report, isScanning: false) {}
                        DetailView(store: store) {}
                    }
                    .environmentObject(settings)
                    .environmentObject(store)
                )
            }
        )
    }

    private static func cleanupList() -> Screen {
        Screen(
            name: "cleanup-list",
            width: 900,
            height: 560,
            stable: true,
            make: { language in
                let settings = TestData.settings(language)
                let store = try TestData.store()
                let report = try #require(store.report)
                return AnyView(
                    VStack(spacing: 0) {
                        ForEach(report.findings) { finding in
                            FindingRow(
                                finding: finding,
                                isSelected: store.selection.contains(finding.id),
                                onToggle: {}
                            )
                        }
                    }
                    .environmentObject(settings)
                    .environmentObject(store)
                )
            }
        )
    }

    private static func confirmSheet() -> Screen {
        Screen(
            name: "confirm-sheet",
            width: 680,
            height: 520,
            stable: true,
            make: { language in
                let settings = TestData.settings(language)
                let store = try TestData.store()
                return AnyView(
                    ConfirmDeleteSheet(
                        findings: store.selectedFindings,
                        totalBytes: store.selectedBytes,
                        onCancel: {},
                        onConfirm: {}
                    )
                    .environmentObject(settings)
                    .environmentObject(store)
                )
            }
        )
    }

    private static func storage() -> Screen {
        Screen(
            name: "storage",
            width: 900,
            height: 640,
            stable: false,
            make: { language in
                let settings = TestData.settings(language)
                let store = try TestData.store(
                    memory: try TestData.memoryReport(),
                    apps: try TestData.apps(),
                    files: try TestData.largeFiles()
                )
                let report = try #require(store.report)
                return AnyView(
                    StorageView(space: TestData.space, reclaimable: report.reclaimable)
                        .environmentObject(settings)
                        .environmentObject(store)
                )
            }
        )
    }

    private static func storageList() -> Screen {
        Screen(
            name: "storage-list",
            width: 900,
            height: 560,
            stable: true,
            make: { language in
                let settings = TestData.settings(language)
                let store = try TestData.store(
                    memory: try TestData.memoryReport(),
                    apps: try TestData.apps(),
                    files: try TestData.largeFiles()
                )
                let apps = try TestData.apps()
                let files = try TestData.largeFiles()
                return AnyView(
                    VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
                        ForEach(apps) { app in
                            AppRow(app: app, isUninstalling: false, onUninstall: {})
                        }
                        ForEach(files) { file in
                            LargeFileRow(file: file, isTrashing: false, onTrash: {})
                        }
                    }
                    .environmentObject(settings)
                    .environmentObject(store)
                )
            }
        )
    }

    private static func memory() -> Screen {
        Screen(
            name: "memory",
            width: 900,
            height: 640,
            stable: true,
            make: { language in
                let settings = TestData.settings(language)
                let store = try TestData.store(memory: try TestData.memoryReport())
                return AnyView(
                    MemoryView()
                        .environmentObject(settings)
                        .environmentObject(store)
                )
            }
        )
    }

    private static func network() -> Screen {
        Screen(
            name: "network",
            width: 900,
            height: 640,
            stable: true,
            make: { language in
                let settings = TestData.settings(language)
                let store = try TestData.store()
                return AnyView(
                    NetView(net: NetControl())
                        .environmentObject(settings)
                        .environmentObject(store)
                )
            }
        )
    }

    private static func menuBar() -> Screen {
        Screen(
            name: "menubar",
            width: 320,
            height: 780,
            stable: false,
            make: { language in
                let settings = TestData.settings(language)
                let store = try TestData.store(
                    memory: try TestData.memoryReport(),
                    apps: try TestData.apps(),
                    files: try TestData.largeFiles()
                )
                return AnyView(
                    MenuBarContent(
                        store: store,
                        router: AppRouter(),
                        net: NetControl(),
                        awdl: AwdlControl(),
                        onOpenWindow: {}
                    )
                    .environmentObject(settings)
                    .environmentObject(store)
                )
            }
        )
    }

    private static func settings() -> Screen {
        Screen(
            name: "settings",
            width: 460,
            height: 640,
            stable: true,
            make: { language in
                let settings = TestData.settings(language)
                let store = try TestData.store()
                return AnyView(
                    VStack(alignment: .leading, spacing: PanelStyle.Space.m) {
                        Text(settings.t("general"))
                            .font(PanelFont.emphasis(.semibold))
                        settingRow(settings.t("language"), settings.t("language"))
                        settingRow(settings.t("theme"), settings.t("system"))
                        settingRow(settings.t("showInDock"), settings.t("showInDockNote"))
                        Divider()
                        Text(settings.t("startup"))
                            .font(PanelFont.emphasis(.semibold))
                        settingRow(settings.t("launchAtLogin"), settings.t("launchAtLoginHelp"))
                        Text(settings.t("startupNote"))
                            .font(PanelFont.caption)
                            .foregroundStyle(.secondary)
                        Divider()
                        Text(settings.t("awdlTitle"))
                            .font(PanelFont.emphasis(.semibold))
                        Text(settings.t("awdlNote"))
                            .font(PanelFont.caption)
                            .foregroundStyle(.secondary)
                        Button(settings.t("awdlInstall")) {}
                        Divider()
                        Text(settings.t("about"))
                            .font(PanelFont.emphasis(.semibold))
                        HStack(spacing: 6) {
                            Text("Dustless")
                                .font(.system(size: 12, weight: .semibold))
                            Text("0.5.0")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(PanelStyle.Space.l)
                    .environmentObject(settings)
                    .environmentObject(store)
                )
            }
        )
    }

    private static func settingRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(PanelFont.emphasis())
            Text(detail)
                .font(PanelFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func unscannable() -> Screen {
        Screen(
            name: "unscannable",
            width: 700,
            height: 160,
            stable: true,
            make: { language in
                let settings = TestData.settings(language)
                let report = try TestData.report()
                return AnyView(
                    UnscannableNotice(report: report, identifier: "overview.unscannable")
                        .environmentObject(settings)
                )
            }
        )
    }

    private static func engineError() -> Screen {
        Screen(
            name: "engine-error",
            width: 900,
            height: 640,
            stable: true,
            make: { language in
                let settings = TestData.settings(language)
                let store = TestData.storeWithError(
                    L10nText("errNotFound", ["list": "/Applications/Dustless.app/Contents/Resources/dustless"])
                )
                return AnyView(
                    DetailView(store: store) {}
                        .environmentObject(settings)
                        .environmentObject(store)
                )
            }
        )
    }

    private static func engineErrorMessage() -> Screen {
        Screen(
            name: "engine-error-message",
            width: 700,
            height: 220,
            stable: true,
            make: { language in
                let settings = TestData.settings(language)
                let store = TestData.storeWithError(
                    L10nText("errNotFound", ["list": "/Applications/Dustless.app/Contents/Resources/dustless"])
                )
                let message = settings.text(store.engineError)
                return AnyView(
                    VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
                        Text(settings.t("engineUnavailable"))
                            .font(PanelFont.emphasis())
                        Text(message)
                            .font(PanelFont.mono(11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(settings.t("nothingDeleted"))
                            .font(PanelFont.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(PanelStyle.Space.m)
                    .environmentObject(settings)
                    .environmentObject(store)
                )
            }
        )
    }

    private static func uninstallSheet() -> Screen {
        Screen(
            name: "uninstall-sheet",
            width: 680,
            height: 520,
            stable: true,
            make: { language in
                let settings = TestData.settings(language)
                let store = try TestData.store(apps: try TestData.apps())
                let app = try #require(try TestData.apps().first)
                return AnyView(
                    UninstallConfirmationSheet(app: app, onCancel: {}, onConfirm: { _ in })
                        .environmentObject(settings)
                        .environmentObject(store)
                )
            }
        )
    }

    private static func trashSheet() -> Screen {
        Screen(
            name: "trash-sheet",
            width: 600,
            height: 360,
            stable: true,
            make: { language in
                let settings = TestData.settings(language)
                let store = try TestData.store(files: try TestData.largeFiles())
                let file = try #require(try TestData.largeFiles().first)
                return AnyView(
                    LargeFileTrashSheet(file: file, onCancel: {}, onConfirm: {})
                        .environmentObject(settings)
                        .environmentObject(store)
                )
            }
        )
    }

    private static func cleanupResult() -> Screen {
        Screen(
            name: "cleanup-result",
            width: 900,
            height: 320,
            stable: true,
            make: { language in
                let settings = TestData.settings(language)
                let store = try TestData.store()
                let report = try TestData.applyReport()
                return AnyView(
                    CleanupResultCard(report: report, onClose: {})
                        .environmentObject(settings)
                        .environmentObject(store)
                )
            }
        )
    }

    private static func tierBadges() -> Screen {
        Screen(
            name: "tier-badges",
            width: 560,
            height: 120,
            stable: true,
            make: { language in
                let settings = TestData.settings(language)
                let store = try TestData.store()
                return AnyView(
                    VStack(alignment: .leading, spacing: PanelStyle.Space.s) {
                        ForEach(Tier.allCases, id: \.self) { tier in
                            TierBadge(tier: tier)
                        }
                    }
                    .environmentObject(settings)
                    .environmentObject(store)
                )
            }
        )
    }

    private static func controls() -> Screen {
        Screen(
            name: "controls",
            width: 560,
            height: 160,
            stable: true,
            make: { language in
                let settings = TestData.settings(language)
                let store = try TestData.store()
                return AnyView(
                    VStack(alignment: .leading, spacing: PanelStyle.Space.m) {
                        DestructiveButton(action: {}) {
                            Text(settings.t("confirmGo"))
                        }
                        Button(settings.t("confirmCancel")) {}
                        Button(role: .destructive, action: {}) {
                            Text(settings.t("appsUninstall"))
                        }
                    }
                    .environmentObject(settings)
                    .environmentObject(store)
                )
            }
        )
    }
}
