import AppKit
import DustlessKit
import Foundation
import SwiftUI
import Testing
@testable import DustlessApp

@Suite("screen pixels")
struct ScreenPixelTests {
    static let factor = 2

    @MainActor
    static func pixels(_ name: String, _ language: Lang = .en) throws -> ScreenRender.Pixels {
        let screen = try Screens.named(name)
        return try Screens.pixels(screen, language)
    }

    @MainActor
    static func referenceRed() throws -> ScreenRender.Colour {
        try ScreenRender.reference(DestructiveStyle.red)
    }

    @MainActor
    static func referenceGreen() throws -> ScreenRender.Colour {
        try ScreenRender.reference(.green)
    }

    @MainActor
    static func referenceOrange() throws -> ScreenRender.Colour {
        try ScreenRender.reference(.orange)
    }

    @Test @MainActor func theDeleteButtonOnTheConfirmSheetIsRed() throws {
        let pixels = try ScreenPixelTests.pixels("confirm-sheet").subsampled(by: ScreenPixelTests.factor)
        let red = try ScreenPixelTests.referenceRed()
        let blobs = pixels.blobs(matching: red, tolerance: 40, minimumSize: 120)
        let button = try #require(blobs.first, "the confirm sheet must paint a red delete button")
        #expect(button.width >= 120, "the delete button must be a wide control, got \(button.width)")
        #expect(button.height >= 12, "the delete button must be a control, got \(button.height)")
        #expect(
            button.centre.isReddish,
            "the delete button must be red, got \(button.centre)"
        )
        let others = blobs.dropFirst().reduce(0) { $0 + $1.count }
        #expect(
            others * 4 < button.count,
            "the confirm sheet must have one red control, found \(blobs.count) red regions"
        )
    }

    @Test @MainActor func theDeleteButtonSitsInTheFooterOnTheRight() throws {
        let pixels = try ScreenPixelTests.pixels("confirm-sheet").subsampled(by: ScreenPixelTests.factor)
        let red = try ScreenPixelTests.referenceRed()
        let button = try #require(pixels.blobs(matching: red, tolerance: 40, minimumSize: 120).first)
        #expect(
            button.y > pixels.height / 2,
            "the delete button must sit in the footer, got y=\(button.y) of \(pixels.height)"
        )
        #expect(
            button.x > pixels.width / 2,
            "the delete button must sit on the right, got x=\(button.x) of \(pixels.width)"
        )
    }

    @Test @MainActor func theCancelButtonIsNotRedAndDiffersFromTheDeleteButton() throws {
        let pixels = try ScreenPixelTests.pixels("confirm-sheet").subsampled(by: ScreenPixelTests.factor)
        let red = try ScreenPixelTests.referenceRed()
        let button = try #require(pixels.blobs(matching: red, tolerance: 40, minimumSize: 120).first)

        let cancelSide = pixels.count(matching: red, tolerance: 40, in: 0, 0, button.x, pixels.height)
        #expect(
            cancelSide == 0,
            "the cancel side of the sheet must carry no red, found \(cancelSide) red pixels"
        )

        let cancelRegion = pixels.averageColour(
            x: 0,
            y: button.y,
            width: max(1, button.x - 8),
            height: button.height
        )
        let deleteRegion = pixels.averageColour(
            x: button.x,
            y: button.y,
            width: button.width,
            height: button.height
        )
        #expect(
            deleteRegion.isReddish,
            "the delete button must read as red, got \(deleteRegion)"
        )
        #expect(
            !cancelRegion.isReddish,
            "the cancel button must not read as red, got \(cancelRegion)"
        )
        #expect(
            deleteRegion.distance(to: cancelRegion) > 60,
            "the destructive button and the cancel button must look different, got \(deleteRegion) and \(cancelRegion)"
        )
    }

    @Test @MainActor func theGreenTierBadgeIsGreen() throws {
        let pixels = try ScreenPixelTests.pixels("cleanup-list").subsampled(by: ScreenPixelTests.factor)
        let green = try ScreenPixelTests.referenceGreen()
        let blobs = pixels.blobs(matching: green, tolerance: 45, minimumSize: 12)
        #expect(!blobs.isEmpty, "the cleanup list must paint the SAFE tier badge green")
        let badge = try #require(blobs.first)
        #expect(
            badge.centre.isGreenish,
            "the SAFE tier badge must be green, got \(badge.centre)"
        )
        #expect(
            badge.x < pixels.width / 4,
            "the tier badge sits at the start of the row, got x=\(badge.x) of \(pixels.width)"
        )
    }

    @Test @MainActor func theYellowTierBadgeIsOrangeAndTheSafeOneIsGreen() throws {
        let pixels = try ScreenPixelTests.pixels("tier-badges").subsampled(by: ScreenPixelTests.factor)
        let orange = try ScreenPixelTests.referenceOrange()
        let orangeBlobs = pixels.blobs(matching: orange, tolerance: 45, minimumSize: 12)
        #expect(!orangeBlobs.isEmpty, "the YOUR CALL tier badge must be orange")
        #expect(try #require(orangeBlobs.first).centre.isOrangish)

        let green = try ScreenPixelTests.referenceGreen()
        let greenBlobs = pixels.blobs(matching: green, tolerance: 45, minimumSize: 12)
        #expect(!greenBlobs.isEmpty, "the SAFE tier badge must be green")
        #expect(try #require(greenBlobs.first).centre.isGreenish)
    }

    @Test @MainActor func theRedTierBadgeIsRed() throws {
        let pixels = try ScreenPixelTests.pixels("tier-badges").subsampled(by: ScreenPixelTests.factor)
        let red = try ScreenPixelTests.referenceRed()
        let blobs = pixels.blobs(matching: red, tolerance: 45, minimumSize: 8)
        #expect(!blobs.isEmpty, "the PROTECTED tier badge must be red")
        #expect(try #require(blobs.first).centre.isReddish)
    }

    @Test @MainActor func theDestructiveTreatmentIsRedWhereverItAppears() throws {
        for name in ["confirm-sheet", "controls"] {
            let pixels = try ScreenPixelTests.pixels(name).subsampled(by: ScreenPixelTests.factor)
            let red = try ScreenPixelTests.referenceRed()
            let count = pixels.count(matching: red, tolerance: 45)
            #expect(count > 100, "\(name) must paint its destructive control red, found \(count) red pixels")
        }
    }

    @Test @MainActor func theSafeTierIsGreenWhereverItAppears() throws {
        for name in ["cleanup-list", "tier-badges"] {
            let pixels = try ScreenPixelTests.pixels(name).subsampled(by: ScreenPixelTests.factor)
            let green = try ScreenPixelTests.referenceGreen()
            let count = pixels.count(matching: green, tolerance: 45)
            #expect(count > 40, "\(name) must paint its SAFE tier badge green, found \(count) green pixels")
        }
    }

    @Test @MainActor func theBlockedReasonIsRed() throws {
        let pixels = try ScreenPixelTests.pixels("cleanup-list").subsampled(by: ScreenPixelTests.factor)
        let red = try ScreenPixelTests.referenceRed()
        let blobs = pixels.blobs(matching: red, tolerance: 45, minimumSize: 4)
        #expect(!blobs.isEmpty, "a blocked finding must state its refusal in red")
    }

    @Test @MainActor func theEngineErrorScreenWarnsInOrange() throws {
        let pixels = try ScreenPixelTests.pixels("engine-error").subsampled(by: ScreenPixelTests.factor)
        let orange = try ScreenPixelTests.referenceOrange()
        let blobs = pixels.blobs(matching: orange, tolerance: 45, minimumSize: 8)
        #expect(!blobs.isEmpty, "the engine error screen must warn in orange")
        #expect(try #require(blobs.first).centre.isOrangish)
    }
}
