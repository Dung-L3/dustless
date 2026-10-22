import AppKit
import Foundation
import SwiftUI

@MainActor
enum ScreenRender {
    enum Failure: Error {
        case notRendered(String)
    }

    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("artifacts/ui-render")

    static func write(
        _ view: some View,
        named name: String,
        width: CGFloat,
        height: CGFloat? = nil
    ) throws -> URL {
        let renderer = ImageRenderer(
            content: view
                .frame(width: width, height: height)
                .environment(\.colorScheme, .light)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure.notRendered(name)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try png.write(to: url)
        return url
    }

    static func pixels(at url: URL) throws -> Int {
        guard let image = NSImage(contentsOf: url) else { throw Failure.notRendered(url.lastPathComponent) }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            throw Failure.notRendered(url.lastPathComponent)
        }
        return bitmap.pixelsWide * bitmap.pixelsHigh
    }
}
