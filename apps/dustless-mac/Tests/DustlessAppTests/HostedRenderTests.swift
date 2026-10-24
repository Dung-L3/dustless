import Testing
import DustlessKit
@testable import DustlessApp

@Suite("hosted renders")
struct HostedRenderTests {
    @Test @MainActor func rendersTheControlsTheImageRendererCannot() throws {
        let names = ["menubar", "overview", "cleanup", "storage", "memory"]
        var written = 0
        for name in names {
            let screen = try Screens.named(name)
            for language in [Lang.en, .vi] {
                let view = try screen.make(language)
                let url = try ScreenRender.writeHosted(
                    view,
                    named: "hosted-\(name)-\(language.rawValue)",
                    width: screen.width,
                    height: screen.height
                )
                let pixels = try ScreenRender.bufferDirect(at: url)
                #expect(pixels.width > 100, "\(url.lastPathComponent) rendered nothing")
                #expect(pixels.height > 100, "\(url.lastPathComponent) rendered nothing")
                #expect(
                    pixels.count(matching: pixels.background(), tolerance: 6) < pixels.width * pixels.height,
                    "\(url.lastPathComponent) is a single flat colour"
                )
                written += 1
            }
        }
        #expect(written == names.count * 2)
    }
}
