import Testing
import Foundation
import DustlessKit

/// The native app's own localization contract. The JS suite checks the Swift
/// tables against the web UI; these check that the Swift views only ask for
/// keys that exist, which is the failure the UI itself cannot show.
private let appSources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // DustlessAppTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // dustless-mac
    .appendingPathComponent("Sources/DustlessApp")

private func swiftViewFiles() throws -> [URL] {
    let enumerator = FileManager.default.enumerator(
        at: appSources,
        includingPropertiesForKeys: nil
    )
    var found: [URL] = []
    while let url = enumerator?.nextObject() as? URL {
        if url.pathExtension == "swift" { found.append(url) }
    }
    #expect(!found.isEmpty, "no Swift sources found under \(appSources.path)")
    return found
}

/// Every literal `t("...")` and `text(L10nText("..."))` key used in a view.
private func keysUsedInViews() throws -> Set<String> {
    var keys: Set<String> = []
    let patterns = [
        #"t\(\s*"([a-zA-Z0-9_]+)""#,
        #"L10nText\(\s*"([a-zA-Z0-9_]+)""#,
    ]
    for url in try swiftViewFiles() {
        let source = try String(contentsOf: url, encoding: .utf8)
        for pattern in patterns {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in regex.matches(in: source, range: range) {
                guard let at = Range(match.range(at: 1), in: source) else { continue }
                keys.insert(String(source[at]))
            }
        }
    }
    return keys
}

@Suite("view localization")
struct ViewLocalizationTests {
    @Test func everyKeyUsedByAViewExistsInAllLanguages() throws {
        let used = try keysUsedInViews()
        #expect(!used.isEmpty, "no keys parsed — the scanner is probably broken")

        var missing: [String] = []
        for lang in Lang.allCases {
            let table = L10n.table(lang)
            for key in used.sorted() where table[key] == nil {
                missing.append("\(lang.rawValue)/\(key)")
            }
        }
        #expect(missing.isEmpty, "keys used by a view but absent from a table: \(missing)")
    }

    @Test func aMissingKeyWouldBeVisibleRatherThanSilent() {
        // L10n falls back to the key itself, so a typo shows up in the UI as
        // raw camelCase. Guard the fallback stays that way.
        #expect(L10n.render(.en, "definitelyNotAKey") == "definitelyNotAKey")
    }

    @Test func interpolatedKeysKeepTheirPlaceholders() {
        // A key dropped from one language would break the visible sentence.
        let interpolated = ["memoryShowingTop", "appsCount", "appsResultSummary", "pathA11y", "confirmTotal"]
        for key in interpolated {
            let english = L10n.render(.en, key, ["shown": "1", "total": "2", "n": "2", "count": "2", "path": "/x", "amount": "1 GB"])
            for lang in Lang.allCases {
                let rendered = L10n.render(lang, key, ["shown": "1", "total": "2", "n": "2", "count": "2", "path": "/x", "amount": "1 GB"])
                #expect(!rendered.contains("{"), "\(lang.rawValue)/\(key) left a placeholder: \(rendered)")
                #expect(rendered != english || lang == .en, "\(lang.rawValue)/\(key) fell back to English")
            }
        }
    }

    @Test func addedPanelStringsExistInEveryLanguage() {
        // The specific strings this change introduced, so a missing translation
        // fails here rather than in the window.
        let added = [
            "close", "refresh", "refreshHelp", "busyMemory", "busyStorage", "busyApps",
            "memoryStopNamed", "memoryForceStopNamed", "memoryStoppedNamed",
            "memoryShowingTop", "memoryNoProcesses", "memoryPressureHelp",
            "volumesEmpty", "volumeUsageHelp", "appsCount", "appsRelatedCount",
            "appsUninstallHelp", "appsUninstallNamed", "appsResultSummary", "outcomeStatus",
            "about", "themeHelp", "themeNote", "launchAtLoginHelp", "settingsLoginError",
        ]
        for key in added {
            for lang in Lang.allCases {
                #expect(L10n.table(lang)[key] != nil, "\(lang.rawValue) is missing \(key)")
            }
        }
    }

    @Test func removedKeysAreGone() {
        // The dead keys the polish dropped; keeping them would invite reuse.
        let removed = [
            "memoryStopProcess", "memoryForceStop", "memoryStopped",
            "diskTotal", "diskUsed", "diskFree", "diskVolume",
            "relatedFiles", "appBundleId", "appSize", "settingsHeading",
        ]
        for key in removed {
            #expect(L10n.table(.en)[key] == nil, "\(key) should have been removed")
        }
    }
}

