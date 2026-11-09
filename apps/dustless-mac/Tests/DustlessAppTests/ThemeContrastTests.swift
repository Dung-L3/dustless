import AppKit
import SwiftUI
import Testing
@testable import DustlessApp

@Suite("theme contrast")
struct ThemeContrastTests {
    private func rgb(_ color: Color, _ appearance: NSAppearance.Name) -> (Double, Double, Double) {
        var result: (Double, Double, Double) = (0, 0, 0)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let resolved = NSColor(color).usingColorSpace(.sRGB)!
            result = (
                Double(resolved.redComponent),
                Double(resolved.greenComponent),
                Double(resolved.blueComponent)
            )
        }
        return result
    }

    private func luminance(_ rgb: (Double, Double, Double)) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.0) + 0.7152 * channel(rgb.1) + 0.0722 * channel(rgb.2)
    }

    private func contrast(_ first: (Double, Double, Double), _ second: (Double, Double, Double)) -> Double {
        let a = luminance(first)
        let b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    @Test @MainActor func thePrimaryActionTextMeetsWCAGAA() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let text = rgb(Theme.Palette.onAccent, appearance)
            let fill = rgb(Theme.Palette.accent, appearance)
            #expect(
                contrast(text, fill) >= 4.5,
                "primary action contrast is \(contrast(text, fill)) in \(appearance.rawValue)"
            )
        }
    }

    @Test @MainActor func theMutedTextMeetsWCAGAAOnRaisedSurfaces() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let text = rgb(Theme.Palette.textMuted, appearance)
            for fill in [Theme.Palette.raised, Theme.Palette.ink] {
                let background = rgb(fill, appearance)
                #expect(
                    contrast(text, background) >= 4.5,
                    "muted text contrast is \(contrast(text, background)) in \(appearance.rawValue)"
                )
            }
        }
    }
}
