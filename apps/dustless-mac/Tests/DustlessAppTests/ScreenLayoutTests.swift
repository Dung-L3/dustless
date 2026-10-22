import AppKit
import DustlessKit
import Foundation
import SwiftUI
import Testing
@testable import DustlessApp

@Suite("screen layout")
struct ScreenLayoutTests {
    static let factor = 2

    static let fixedGeometry = [
        "cleanup-list",
        "storage-list",
        "memory",
        "unscannable",
        "cleanup-result",
        "trash-sheet",
        "uninstall-sheet",
        "engine-error",
        "tier-badges",
        "controls"
    ]

    @MainActor
    static func bands(_ name: String, _ language: Lang) throws -> [ScreenRender.Band] {
        let screen = try Screens.named(name)
        let pixels = try Screens.pixels(screen, language).subsampled(by: factor)
        return pixels.bands(mask: pixels.inkMask(), minimumInk: 1, gap: 3)
    }

    @Test @MainActor func everyFixedScreenHasTheSameRowsInEveryLanguage() throws {
        for name in ScreenLayoutTests.fixedGeometry {
            let reference = try ScreenLayoutTests.bands(name, .en)
            #expect(!reference.isEmpty, "\(name) must draw something")
            for language in Lang.allCases where language != .en {
                let bands = try ScreenLayoutTests.bands(name, language)
                #expect(
                    bands.count == reference.count,
                    "\(name) draws \(reference.count) rows in English and \(bands.count) in \(language.rawValue)"
                )
                guard bands.count == reference.count else { continue }
                for (index, band) in bands.enumerated() {
                    let expected = reference[index]
                    #expect(
                        abs(band.centreY - expected.centreY) <= 4,
                        "\(name) row \(index) moved from \(expected.centreY) to \(band.centreY) in \(language.rawValue)"
                    )
                }
            }
        }
    }

    @Test @MainActor func theLeadingEdgeOfAListDoesNotMoveBetweenLanguages() throws {
        for name in ["cleanup-list", "storage-list", "trash-sheet", "uninstall-sheet"] {
            let reference = try ScreenLayoutTests.bands(name, .en)
            let leading = reference.filter { $0.left <= (reference.first?.left ?? 0) + 8 }
            #expect(!leading.isEmpty, "\(name) must have a leading edge")
            for language in Lang.allCases where language != .en {
                let bands = try ScreenLayoutTests.bands(name, language)
                guard bands.count == reference.count else { continue }
                for (index, expected) in leading.enumerated() where index < bands.count {
                    #expect(
                        abs(bands[index].left - expected.left) <= 4,
                        "\(name) row \(index) starts at \(expected.left) in English and \(bands[index].left) in \(language.rawValue)"
                    )
                }
            }
        }
    }

    @Test @MainActor func theDeleteButtonDoesNotMoveBetweenLanguages() throws {
        let screen = try Screens.named("confirm-sheet")
        let red = try ScreenRender.reference(DestructiveStyle.red)
        var boxes: [(Int, Int)] = []
        for language in Lang.allCases {
            let pixels = try Screens.pixels(screen, language).subsampled(by: ScreenLayoutTests.factor)
            let button = try #require(
                pixels.blobs(matching: red, tolerance: 40, minimumSize: 120).first,
                "the confirm sheet must paint a red delete button in \(language.rawValue)"
            )
            boxes.append((button.x, button.y))
        }
        for box in boxes.dropFirst() {
            #expect(
                abs(box.0 - boxes[0].0) <= 4 && abs(box.1 - boxes[0].1) <= 4,
                "the delete button moved between languages: \(boxes)"
            )
        }
    }

    @Test @MainActor func aNarrowerScreenHasADifferentLayout() throws {
        let settings = TestData.settings(.en)
        let store = try TestData.store()
        let report = try #require(store.report)
        func rows() -> some View {
            VStack(spacing: 0) {
                ForEach(report.findings) { finding in
                    FindingRow(finding: finding, isSelected: false, onToggle: {})
                }
            }
            .environmentObject(settings)
            .environmentObject(store)
        }
        let wide = try ScreenRender.buffer(of: rows(), width: 900)
        let narrow = try ScreenRender.buffer(of: rows(), width: 460)
        let wideBands = wide.bands(mask: wide.inkMask(), minimumInk: 1, gap: 3)
        let narrowBands = narrow.bands(mask: narrow.inkMask(), minimumInk: 1, gap: 3)
        #expect(
            wideBands.count != narrowBands.count || wideBands[0].left != narrowBands[0].left,
            "a narrower screen must lay out differently, otherwise the layout check proves nothing"
        )
    }
}
