import AppKit
import DustlessKit
import Foundation
import SwiftUI
import Testing
@testable import DustlessApp

@Suite("screen renders")
struct ViewRenderTests {
    @MainActor
    static func report() throws -> ScanReport {
        try JSONDecoder().decode(ScanReport.self, from: fixture("scan.json"))
    }

    @MainActor
    static func memoryReport() throws -> MemoryReport {
        try JSONDecoder().decode(MemoryReport.self, from: fixture("ram.json"))
    }

    @MainActor
    static func apps() throws -> [InstalledApp] {
        try JSONDecoder().decode([InstalledApp].self, from: fixture("apps.json"))
    }

    @MainActor
    static func largeFiles() throws -> [LargeFile] {
        try JSONDecoder().decode([LargeFile].self, from: fixture("largefiles.json"))
    }

    static let space = DiskSpace(
        volumeName: "Macintosh HD",
        total: 994_662_584_320,
        used: 512_106_500_096,
        available: 482_556_084_224
    )

    @MainActor
    static func settings(_ language: Lang) -> AppSettings {
        let settings = AppSettings()
        settings.language = language
        return settings
    }

    @MainActor
    static func store(
        report: ScanReport,
        memory: MemoryReport,
        apps: [InstalledApp],
        files: [LargeFile]
    ) -> ScanStore {
        ScanStore(
            preview: ScanStore.Preview(
                report: report,
                scannedAt: Date(timeIntervalSince1970: 1_788_000_000),
                memoryReport: memory,
                diskSpace: space,
                storageVolumes: [
                    VolumeInfo(name: "Macintosh HD", total: space.total, used: space.used, free: space.available),
                ],
                storageApps: apps,
                storageLargeFiles: files,
                selected: Set(report.deletable.prefix(2).map(\.id))
            )
        )
    }

    @Test @MainActor func rendersEveryScreenOffScreen() throws {
        let report = try Self.report()
        let memory = try Self.memoryReport()
        let apps = try Self.apps()
        let files = try Self.largeFiles()
        let settings = Self.settings(.en)
        let store = Self.store(report: report, memory: memory, apps: apps, files: files)
        let router = AppRouter()
        let net = NetControl()

        var written: [URL] = []

        written.append(
            try ScreenRender.write(
                OverviewView(store: store, net: net, router: router)
                    .environmentObject(settings)
                    .environmentObject(store),
                named: "overview",
                width: 900,
                height: 640
            )
        )

        written.append(
            try ScreenRender.write(
                VStack(spacing: 0) {
                    SummaryHeader(report: report, isScanning: false) {}
                    DetailView(store: store) {}
                }
                .environmentObject(settings)
                .environmentObject(store),
                named: "cleanup",
                width: 900,
                height: 640
            )
        )

        written.append(
            try ScreenRender.write(
                VStack(spacing: 0) {
                    ForEach(report.deletable.prefix(4)) { finding in
                        FindingRow(finding: finding, isSelected: false, onToggle: {})
                    }
                }
                .environmentObject(settings)
                .environmentObject(store),
                named: "cleanup-rows",
                width: 900,
                height: 420
            )
        )

        written.append(
            try ScreenRender.write(
                ConfirmDeleteSheet(
                    findings: store.selectedFindings,
                    totalBytes: store.selectedBytes,
                    onCancel: {},
                    onConfirm: {}
                )
                .environmentObject(settings)
                .environmentObject(store),
                named: "confirm",
                width: 680,
                height: 520
            )
        )

        written.append(
            try ScreenRender.write(
                StorageView(space: Self.space, reclaimable: report.reclaimable)
                    .environmentObject(settings)
                    .environmentObject(store),
                named: "storage",
                width: 900,
                height: 640
            )
        )

        written.append(
            try ScreenRender.write(
                MemoryView()
                    .environmentObject(settings)
                    .environmentObject(store),
                named: "memory",
                width: 900,
                height: 640
            )
        )

        written.append(
            try ScreenRender.write(
                NetView(net: net)
                    .environmentObject(settings)
                    .environmentObject(store),
                named: "network",
                width: 900,
                height: 640
            )
        )

        written.append(
            try ScreenRender.write(
                MenuBarContent(store: store, router: router, net: net, awdl: .shared, onOpenWindow: {})
                    .environmentObject(settings)
                    .environmentObject(store),
                named: "menubar",
                width: 320,
                height: 420
            )
        )

        written.append(
            try ScreenRender.write(
                UnscannableNotice(report: report, identifier: "overview.unscannable")
                    .environmentObject(settings),
                named: "unscannable",
                width: 700,
                height: 160
            )
        )

        for url in written {
            let pixels = try ScreenRender.pixels(at: url)
            #expect(pixels > 10_000, "\(url.lastPathComponent) rendered empty")
        }
    }

    @Test @MainActor func rendersTheSameScreenInEveryLanguage() throws {
        let report = try Self.report()
        let memory = try Self.memoryReport()
        let apps = try Self.apps()
        let files = try Self.largeFiles()
        let store = Self.store(report: report, memory: memory, apps: apps, files: files)
        let router = AppRouter()
        let net = NetControl()

        for language in Lang.allCases {
            let settings = Self.settings(language)
            let url = try ScreenRender.write(
                ConfirmDeleteSheet(
                    findings: store.selectedFindings,
                    totalBytes: store.selectedBytes,
                    onCancel: {},
                    onConfirm: {}
                )
                .environmentObject(settings)
                .environmentObject(store),
                named: "confirm-\(language.rawValue)",
                width: 680,
                height: 520
            )
            #expect(try ScreenRender.pixels(at: url) > 10_000)
        }
    }
}
