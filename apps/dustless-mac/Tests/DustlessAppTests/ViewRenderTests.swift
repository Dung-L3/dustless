import AppKit
import DustlessKit
import Foundation
import SwiftUI
import Testing
@testable import DustlessApp

@MainActor
extension Screens {
    static func render(_ screen: Screen, _ language: Lang) throws -> URL {
        let view = try screen.make(language)
        return try ScreenRender.write(
            view,
            named: "\(screen.name)-\(language.rawValue)",
            width: screen.width,
            height: screen.height
        )
    }

    static func pixels(_ screen: Screen, _ language: Lang) throws -> ScreenRender.Pixels {
        let url = try render(screen, language)
        return try ScreenRender.buffer(at: url)
    }

    static func named(_ name: String) throws -> Screen {
        guard let screen = try all().first(where: { $0.name == name }) else {
            throw ScreenRender.Failure.notRendered(name)
        }
        return screen
    }
}

@Suite("screen renders")
struct ViewRenderTests {
    @Test @MainActor func rendersEveryScreenInEveryLanguage() throws {
        let screens = try Screens.all()
        var written = 0
        for screen in screens {
            for language in Lang.allCases {
                let url = try Screens.render(screen, language)
                let pixels = try ScreenRender.pixels(at: url)
                #expect(pixels > 10_000, "\(url.lastPathComponent) rendered empty")
                #expect(
                    FileManager.default.fileExists(atPath: url.path),
                    "missing render artifact \(url.lastPathComponent)"
                )
                written += 1
            }
        }
        #expect(written == screens.count * Lang.allCases.count)
        #expect(screens.count >= 18, "the catalogue must cover every screen that matters")
    }

    @Test @MainActor func everyScreenDrawsSomething() throws {
        for screen in try Screens.all() {
            let pixels = try Screens.pixels(screen, .en)
            let mask = pixels.inkMask()
            let bands = pixels.bands(mask: mask, minimumInk: 1, gap: 3)
            #expect(
                bands.count >= 1,
                "\(screen.name) drew nothing; it must draw its chrome"
            )
            #expect(
                pixels.count(matching: pixels.background(), tolerance: 6) < pixels.width * pixels.height,
                "\(screen.name) is a single flat colour"
            )
        }
    }

    @Test @MainActor func theSameScreenRendersTheSameWayTwice() throws {
        for name in ["cleanup-list", "confirm-sheet", "storage-list", "tier-badges"] {
            let screen = try Screens.named(name)
            let first = try Screens.pixels(screen, .en)
            let second = try Screens.pixels(screen, .en)
            #expect(
                first.width == second.width && first.height == second.height,
                "\(name) changed size between renders"
            )
            let firstBands = first.bands(mask: first.inkMask(), minimumInk: 1, gap: 3)
            let secondBands = second.bands(mask: second.inkMask(), minimumInk: 1, gap: 3)
            #expect(
                firstBands.count == secondBands.count,
                "\(name) rendered \(firstBands.count) bands then \(secondBands.count); the render must be stable"
            )
        }
    }
}
