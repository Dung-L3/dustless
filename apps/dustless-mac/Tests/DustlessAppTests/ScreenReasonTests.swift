import AppKit
import DustlessKit
import Foundation
import SwiftUI
import Testing
@testable import DustlessApp

@Suite("reason text on screen")
struct ScreenReasonTests {
    static let factor = 2

    @MainActor
    static func rowPixels(_ finding: Finding, _ language: Lang = .en) throws -> ScreenRender.Pixels {
        let settings = TestData.settings(language)
        let store = try TestData.store(report: nil)
        return try ScreenRender.buffer(
            of: FindingRow(finding: finding, isSelected: false, onToggle: {})
                .environmentObject(settings)
                .environmentObject(store),
            width: 900
        )
    }

    @MainActor
    static func noteWidth(_ text: String, _ language: Lang = .en) throws -> Int {
        let settings = TestData.settings(language)
        let store = try TestData.store(report: nil)
        let pixels = try ScreenRender.buffer(
            of: HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(nil)
            }
            .font(PanelFont.caption)
            .foregroundStyle(Color.secondary)
            .environmentObject(settings)
            .environmentObject(store),
            width: 900
        )
        let mask = pixels.inkMask()
        let bands = pixels.bands(mask: mask, minimumInk: 1, gap: 3)
        guard let band = bands.first else { return 0 }
        return band.right - band.left
    }

    @Test @MainActor func theReasonOnTheScreenChangesWithItsParameters() throws {
        let first = try finding(
            tier: "yellow",
            blocked: false,
            bytes: 10,
            path: "/tmp/reason/one",
            note: [Reason(code: "min_age", params: ["age": "0.0", "min": "30"])]
        )
        let second = try finding(
            tier: "yellow",
            blocked: false,
            bytes: 10,
            path: "/tmp/reason/one",
            note: [Reason(code: "min_age", params: ["age": "7.5", "min": "30"])]
        )
        let firstPixels = try ScreenReasonTests.rowPixels(first)
        let secondPixels = try ScreenReasonTests.rowPixels(second)
        let firstMask = firstPixels.inkMask()
        let secondMask = secondPixels.inkMask()
        let differing = zip(firstMask, secondMask).reduce(0) { count, pair in
            pair.0 != pair.1 ? count + 1 : count
        }
        #expect(
            differing > 20,
            "the screen must show the reason's parameters, otherwise it shows the raw code"
        )
    }

    @Test @MainActor func theReasonOnTheScreenIsASentenceAndNotTheRawCode() throws {
        let reason = Reason(code: "min_age", params: ["age": "0.0", "min": "30"])
        let row = try finding(
            tier: "yellow",
            blocked: false,
            bytes: 10,
            path: "/tmp/reason/one",
            note: [reason]
        )
        let pixels = try ScreenReasonTests.rowPixels(row)
        let bands = pixels.bands(mask: pixels.inkMask(), minimumInk: 1, gap: 3)
        let note = try #require(bands.last, "the row must draw its reason")
        let sentenceWidth = try ScreenReasonTests.noteWidth(ReasonText.text(reason, lang: .en))
        let rawCodeWidth = try ScreenReasonTests.noteWidth("min_age")
        let rowWidth = note.right - note.left

        #expect(
            sentenceWidth > 0 && rawCodeWidth > 0,
            "the references must draw"
        )
        #expect(
            rowWidth >= rawCodeWidth * 5 / 2,
            "the reason must be a sentence, not a raw code: row \(rowWidth), code \(rawCodeWidth)"
        )
        #expect(
            abs(rowWidth - sentenceWidth) <= sentenceWidth / 4,
            "the reason must be the translated sentence: row \(rowWidth), sentence \(sentenceWidth)"
        )
    }

    @Test @MainActor func everyReasonInTheFixtureHasASentenceInEveryLanguage() throws {
        let report = try TestData.report()
        let codes = Set(report.findings.flatMap { $0.note.map(\.code) })
        #expect(!codes.isEmpty, "the fixture must carry reasons to translate")
        for code in codes {
            for language in Lang.allCases {
                let reason = Reason(code: code, params: ["age": "1", "min": "30", "cause": "unknown"])
                let rendered = ReasonText.text(reason, lang: language)
                #expect(
                    rendered != code,
                    "\(code) must not be shown as itself in \(language.rawValue)"
                )
                #expect(
                    !rendered.hasPrefix("reason."),
                    "\(code) has no translation in \(language.rawValue), it renders as \(rendered)"
                )
                #expect(
                    rendered.count > 4,
                    "\(code) must render as a sentence in \(language.rawValue), got \(rendered)"
                )
            }
        }
    }

    @Test func theReasonTableCoversEveryCodeTheEngineCanSend() throws {
        let vocabulary = try engineReasonCodes()
        #expect(vocabulary.count > 20, "the engine vocabulary must be found")
        for code in vocabulary {
            for language in Lang.allCases {
                let rendered = L10n.render(language, "reason.\(code)", ["age": "1", "min": "30"])
                #expect(
                    rendered != "reason.\(code)",
                    "\(code) has no translation in \(language.rawValue)"
                )
            }
        }
    }

    private func engineReasonCodes() throws -> [String] {
        let types = repoRoot
            .appendingPathComponent("src")
            .appendingPathComponent("types.ts")
        let source = try String(contentsOf: types, encoding: .utf8)
        guard let start = source.range(of: "export type ReasonCode =") else { return [] }
        guard let end = source.range(of: ";", range: start.upperBound..<source.endIndex) else { return [] }
        let block = source[start.upperBound..<end.lowerBound]
        return block.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("| \"") else { return nil }
            return trimmed.replacingOccurrences(of: "| \"", with: "")
                .replacingOccurrences(of: "\"", with: "")
        }
    }
}
