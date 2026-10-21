import Testing
import Foundation
import DustlessKit
@Suite("apps model")
struct AppsModelTests {
    @Test func decodesInstalledAppList() throws {
        let apps = try JSONDecoder().decode([InstalledApp].self, from: fixture("apps.json"))
        #expect(apps.count == 3)
        let first = try #require(apps.first)
        #expect(!first.name.isEmpty)
        #expect(first.path.hasSuffix(".app"))
        #expect(!first.bundleId.isEmpty)
        #expect(first.bytes > 0)
        #expect(first.relatedPaths.allSatisfy { $0.hasPrefix("/") || $0.hasPrefix("~") })
    }

    @Test func installedAppsSortByBytesDescending() throws {
        let apps = try JSONDecoder().decode([InstalledApp].self, from: fixture("apps.json"))
        let bytes = apps.map(\.bytes).sorted(by: >)
        #expect(apps.sorted { $0.bytes > $1.bytes }.map(\.bytes) == bytes)
    }

    @Test func decodesUninstallReport() throws {
        let report = try JSONDecoder().decode(UninstallReport.self, from: fixture("uninstall.json"))
        #expect(report.outcomes.count == 3)
        #expect(report.outcomes[0].status == .trashed)
        #expect(report.outcomes[2].status == .skipped)
        #expect(report.summary.trashed == 2)
        #expect(report.summary.purged == 0)
        #expect(report.summary.skipped == 1)
        #expect(report.summary.failed == 0)
        #expect(report.summary.totalBytes == 133942549)
    }

    @Test func uninstallStatusCoversAllCases() {
        #expect(UninstallOutcome.Status.allCases.count == 4)
        #expect(UninstallOutcome.Status(rawValue: "trashed") != nil)
        #expect(UninstallOutcome.Status(rawValue: "purged") != nil)
        #expect(UninstallOutcome.Status(rawValue: "skipped") != nil)
        #expect(UninstallOutcome.Status(rawValue: "failed") != nil)
    }

    @Test func rejectsMalformedAppsPayload() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([InstalledApp].self, from: Data(#"{"bundleId":"nope"}"#.utf8))
        }
    }

    @Test func rejectsMalformedUninstallReport() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(UninstallReport.self, from: Data(#"{"outcomes":"nope"}"#.utf8))
        }
    }

    @Test func thePurgeConfirmationIsTranslatedInEveryLanguage() {
        for key in ["appsPurgeTitle", "appsPurgeBody", "appsPurgeAction"] {
            for lang in Lang.allCases {
                #expect(L10n.table(lang)[key] != nil, "\(lang)/\(key)")
            }
        }
        for lang in Lang.allCases {
            #expect(L10n.render(lang, "appsPurgeBody", ["n": "3"]).contains("3"), "\(lang)")
            #expect(!L10n.render(lang, "appsPurgeBody", ["n": "3"]).contains("{n}"), "\(lang)")
        }
    }
}

@Suite("largest files model")
struct LargeFilesModelTests {
    @Test func decodesLargeFileList() throws {
        let files = try JSONDecoder().decode([LargeFile].self, from: fixture("largefiles.json"))
        #expect(files.count == 3)
        let first = try #require(files.first)
        #expect(first.name == "screen recording.mov")
        #expect(first.path.hasPrefix("/"))
        #expect(first.size == 4_823_449_600)
        #expect(abs(first.modified.timeIntervalSince1970 - 1_680_674_828) < 1)
        #expect(files.allSatisfy { $0.size > 0 })
    }

    @Test func largeFilesSortBySizeDescending() throws {
        let files = try JSONDecoder().decode([LargeFile].self, from: fixture("largefiles.json"))
        let sizes = files.map(\.size).sorted(by: >)
        #expect(files.sorted { $0.size > $1.size }.map(\.size) == sizes)
    }

    @Test func distinctPathsStayDistinctFiles() throws {
        let files = try JSONDecoder().decode([LargeFile].self, from: fixture("largefiles.json"))
        #expect(Set(files.map(\.path)).count == files.count)
        #expect(Set(files.map(\.id)).count == files.count)
    }

    @Test func rejectsMalformedLargeFilePayload() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([LargeFile].self, from: Data(#"[{"size":1}]"#.utf8))
        }
    }

    @Test func rejectsFileWithoutSize() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([LargeFile].self, from: Data(#"[{"path":"/a","mtime":0}]"#.utf8))
        }
    }
}
