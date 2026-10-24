import AppKit
import Foundation
import SwiftUI

@MainActor
enum ScreenRender {
    enum Failure: Error {
        case notRendered(String)
        case unreadable(String)
    }

    struct Colour: Equatable, Hashable {
        let red: Int
        let green: Int
        let blue: Int

        func distance(to other: Colour) -> Int {
            max(abs(red - other.red), max(abs(green - other.green), abs(blue - other.blue)))
        }

        var isReddish: Bool { red > 140 && green < 110 && blue < 110 && red - green > 60 }

        var isGreenish: Bool { green > 110 && green - red > 50 && green - blue > 30 }

        var isOrangish: Bool { red > 170 && green > 90 && green < 190 && blue < 90 }
    }

    struct Blob {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let count: Int
        let centre: Colour
    }

    struct Band {
        let top: Int
        let bottom: Int
        let left: Int
        let right: Int
        let count: Int

        var centreY: Double { Double(top + bottom) / 2 }
        var height: Int { bottom - top }
    }

    struct Pixels {
        let width: Int
        let height: Int
        private let buffer: [UInt8]

        init(width: Int, height: Int, buffer: [UInt8]) {
            self.width = width
            self.height = height
            self.buffer = buffer
        }

        func colour(x: Int, y: Int) -> Colour {
            guard x >= 0, x < width, y >= 0, y < height else { return Colour(red: 255, green: 255, blue: 255) }
            let offset = (y * width + x) * 4
            return Colour(
                red: Int(buffer[offset]),
                green: Int(buffer[offset + 1]),
                blue: Int(buffer[offset + 2])
            )
        }

        func background() -> Colour {
            var histogram = [Int](repeating: 0, count: 4096)
            var representatives = [Colour?](repeating: nil, count: 4096)
            buffer.withUnsafeBufferPointer { pointer in
                var y = 0
                while y < height {
                    var x = 0
                    while x < width {
                        let offset = (y * width + x) * 4
                        let red = Int(pointer[offset])
                        let green = Int(pointer[offset + 1])
                        let blue = Int(pointer[offset + 2])
                        let key = (red >> 4) << 8 | (green >> 4) << 4 | (blue >> 4)
                        histogram[key] += 1
                        if representatives[key] == nil {
                            representatives[key] = Colour(red: red, green: green, blue: blue)
                        }
                        x += 3
                    }
                    y += 3
                }
            }
            var bestKey = 0
            var bestCount = -1
            for key in 0..<4096 where histogram[key] > bestCount {
                bestCount = histogram[key]
                bestKey = key
            }
            return representatives[bestKey] ?? Colour(red: 255, green: 255, blue: 255)
        }

        func inkMask(threshold: Int = 26) -> [UInt8] {
            let base = background()
            let total = width * height
            var mask = [UInt8](repeating: 0, count: total)
            let red = base.red
            let green = base.green
            let blue = base.blue
            buffer.withUnsafeBufferPointer { source in
                mask.withUnsafeMutableBufferPointer { target in
                    for index in 0..<total {
                        let offset = index * 4
                        let delta = max(
                            abs(Int(source[offset]) - red),
                            max(abs(Int(source[offset + 1]) - green), abs(Int(source[offset + 2]) - blue))
                        )
                        target[index] = delta > threshold ? 1 : 0
                    }
                }
            }
            return mask
        }

        func bands(mask: [UInt8], minimumInk: Int = 1, gap: Int = 3) -> [Band] {
            var rowInk = [Int](repeating: 0, count: height)
            mask.withUnsafeBufferPointer { source in
                for y in 0..<height {
                    var count = 0
                    let base = y * width
                    for x in 0..<width where source[base + x] != 0 { count += 1 }
                    rowInk[y] = count
                }
            }
            var result: [Band] = []
            var index = 0
            while index < height {
                guard rowInk[index] >= minimumInk else {
                    index += 1
                    continue
                }
                var end = index
                var blank = 0
                var cursor = index
                while cursor < height {
                    if rowInk[cursor] >= minimumInk {
                        end = cursor
                        blank = 0
                    } else {
                        blank += 1
                        if blank > gap { break }
                    }
                    cursor += 1
                }
                result.append(band(from: index, to: end, mask: mask))
                index = end + 1
            }
            return result
        }

        private func band(from top: Int, to bottom: Int, mask: [UInt8]) -> Band {
            var left = width
            var right = -1
            var count = 0
            mask.withUnsafeBufferPointer { source in
                for y in top...bottom {
                    let base = y * width
                    for x in 0..<width where source[base + x] != 0 {
                        if x < left { left = x }
                        if x > right { right = x }
                        count += 1
                    }
                }
            }
            return Band(top: top, bottom: bottom, left: left, right: right, count: count)
        }

        func blobs(matching reference: Colour, tolerance: Int, minimumSize: Int = 24) -> [Blob] {
            let total = width * height
            var mask = [UInt8](repeating: 0, count: total)
            buffer.withUnsafeBufferPointer { source in
                mask.withUnsafeMutableBufferPointer { target in
                    for index in 0..<total {
                        let offset = index * 4
                        let delta = max(
                            abs(Int(source[offset]) - reference.red),
                            max(abs(Int(source[offset + 1]) - reference.green), abs(Int(source[offset + 2]) - reference.blue))
                        )
                        target[index] = delta <= tolerance ? 1 : 0
                    }
                }
            }
            var seen = [UInt8](repeating: 0, count: total)
            var found: [Blob] = []
            var queue: [Int] = []
            queue.reserveCapacity(4096)
            mask.withUnsafeBufferPointer { source in
                seen.withUnsafeMutableBufferPointer { visited in
                    for y in 0..<height {
                        for x in 0..<width {
                            let start = y * width + x
                            guard source[start] != 0, visited[start] == 0 else { continue }
                            queue.removeAll(keepingCapacity: true)
                            queue.append(start)
                            visited[start] = 1
                            var minX = x
                            var maxX = x
                            var minY = y
                            var maxY = y
                            var count = 0
                            var sumR = 0
                            var sumG = 0
                            var sumB = 0
                            var head = 0
                            while head < queue.count {
                                let index = queue[head]
                                head += 1
                                let cx = index % width
                                let cy = index / width
                                count += 1
                                let offset = index * 4
                                sumR += Int(buffer[offset])
                                sumG += Int(buffer[offset + 1])
                                sumB += Int(buffer[offset + 2])
                                if cx < minX { minX = cx }
                                if cx > maxX { maxX = cx }
                                if cy < minY { minY = cy }
                                if cy > maxY { maxY = cy }
                                for dy in -1...1 {
                                    for dx in -1...1 {
                                        let nx = cx + dx
                                        let ny = cy + dy
                                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                                        let at = ny * width + nx
                                        guard source[at] != 0, visited[at] == 0 else { continue }
                                        visited[at] = 1
                                        queue.append(at)
                                    }
                                }
                            }
                            if count >= minimumSize {
                                found.append(Blob(
                                    x: minX,
                                    y: minY,
                                    width: maxX - minX + 1,
                                    height: maxY - minY + 1,
                                    count: count,
                                    centre: Colour(
                                        red: sumR / count,
                                        green: sumG / count,
                                        blue: sumB / count
                                    )
                                ))
                            }
                        }
                    }
                }
            }
            return found.sorted { $0.count > $1.count }
        }

        func count(matching target: Colour, tolerance: Int) -> Int {
            count(matching: target, tolerance: tolerance, in: 0, 0, width, height)
        }

        func count(
            matching target: Colour,
            tolerance: Int,
            in x: Int,
            _ y: Int,
            _ regionWidth: Int,
            _ regionHeight: Int
        ) -> Int {
            var total = 0
            let left = max(0, x)
            let top = max(0, y)
            let right = min(width, x + regionWidth)
            let bottom = min(height, y + regionHeight)
            guard right > left, bottom > top else { return 0 }
            buffer.withUnsafeBufferPointer { source in
                for row in top..<bottom {
                    let base = row * width
                    for column in left..<right {
                        let offset = (base + column) * 4
                        let delta = max(
                            abs(Int(source[offset]) - target.red),
                            max(abs(Int(source[offset + 1]) - target.green), abs(Int(source[offset + 2]) - target.blue))
                        )
                        if delta <= tolerance { total += 1 }
                    }
                }
            }
            return total
        }

        func subsampled(by factor: Int) -> Pixels {
            guard factor > 1 else { return self }
            let newWidth = width / factor
            let newHeight = height / factor
            var out = [UInt8](repeating: 0, count: newWidth * newHeight * 4)
            for y in 0..<newHeight {
                let sourceRow = (y * factor) * width
                let destinationRow = y * newWidth
                for x in 0..<newWidth {
                    let source = (sourceRow + x * factor) * 4
                    let destination = (destinationRow + x) * 4
                    out[destination] = buffer[source]
                    out[destination + 1] = buffer[source + 1]
                    out[destination + 2] = buffer[source + 2]
                    out[destination + 3] = buffer[source + 3]
                }
            }
            return Pixels(width: newWidth, height: newHeight, buffer: out)
        }

        func averageColour(x: Int, y: Int, width: Int, height: Int) -> Colour {
            var sumR = 0
            var sumG = 0
            var sumB = 0
            var count = 0
            for row in y..<(y + height) {
                for column in x..<(x + width) {
                    guard column >= 0, column < self.width, row >= 0, row < self.height else { continue }
                    let offset = (row * self.width + column) * 4
                    sumR += Int(buffer[offset])
                    sumG += Int(buffer[offset + 1])
                    sumB += Int(buffer[offset + 2])
                    count += 1
                }
            }
            guard count > 0 else { return Colour(red: 255, green: 255, blue: 255) }
            return Colour(red: sumR / count, green: sumG / count, blue: sumB / count)
        }
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
    ) throws -> URL {        let renderer = ImageRenderer(
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

    static func writeHosted(
        _ view: some View,
        named name: String,
        width: CGFloat,
        height: CGFloat
    ) throws -> URL {
        let size = NSSize(width: width, height: height)
        let hosting = NSHostingView(rootView: view.frame(width: width, height: height))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw Failure.notRendered(name)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let captured = bitmap.cgImage else { throw Failure.notRendered(name) }
        let width = captured.width
        let height = captured.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw Failure.notRendered(name) }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(captured, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let opaque = context.makeImage() else { throw Failure.notRendered(name) }
        guard let png = NSBitmapImageRep(cgImage: opaque).representation(using: .png, properties: [:]) else {
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

    static func buffer(at url: URL) throws -> Pixels {
        guard let image = NSImage(contentsOf: url) else { throw Failure.unreadable(url.lastPathComponent) }
        return try buffer(of: image, named: url.lastPathComponent)
    }

    static func bufferDirect(at url: URL) throws -> Pixels {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        return try buffer(of: image, named: url.lastPathComponent)
    }

    static func buffer(of image: NSImage, named name: String) throws -> Pixels {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw Failure.unreadable(name)
        }
        return try buffer(of: cgImage, named: name)
    }

    static func buffer(of cgImage: CGImage, named name: String) throws -> Pixels {
        let width = cgImage.width
        let height = cgImage.height
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let drawn: Bool = raw.withUnsafeMutableBytes { pointer -> Bool in
            guard let context = CGContext(
                data: pointer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw Failure.unreadable(name) }
        var flipped = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let source = (height - 1 - y) * width * 4
            let destination = y * width * 4
            for index in 0..<(width * 4) {
                flipped[destination + index] = raw[source + index]
            }
        }
        return Pixels(width: width, height: height, buffer: flipped)
    }

    static func buffer(of view: some View, width: CGFloat, height: CGFloat? = nil) throws -> Pixels {
        let renderer = ImageRenderer(
            content: view
                .frame(width: width, height: height)
                .environment(\.colorScheme, .light)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = 2
        guard let image = renderer.nsImage else { throw Failure.notRendered("inline") }
        return try buffer(of: image, named: "inline")
    }

    static func reference(_ color: Color) throws -> Colour {
        let renderer = ImageRenderer(
            content: Rectangle()
                .fill(color)
                .frame(width: 40, height: 40)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage else { throw Failure.notRendered("reference") }
        let pixels = try buffer(of: image, named: "reference")
        return pixels.colour(x: pixels.width / 2, y: pixels.height / 2)
    }
}
