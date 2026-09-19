import BrowsemiumCore
import AppKit
import CoreGraphics
import Foundation

enum ScreenshotEncoder {
    static func encode(_ image: NSImage, maxDimension: Int, maxBytes: Int) throws -> PageImageContext {
        guard let source = cgImage(from: image) else {
            throw BrowsemiumError.captureFailed("The page snapshot could not be read.")
        }

        var working = source
        var dimension = maxDimension

        for attempt in 0..<4 {
            let scaled = try downscaled(working, maxDimension: dimension)
            if let png = encodePNG(scaled), png.count <= maxBytes {
                return PageImageContext(data: png, mimeType: "image/png", width: scaled.width, height: scaled.height)
            }
            if let jpeg = encodeJPEG(scaled, quality: attempt < 2 ? 0.7 : 0.5), jpeg.count <= maxBytes {
                return PageImageContext(data: jpeg, mimeType: "image/jpeg", width: scaled.width, height: scaled.height)
            }
            working = scaled
            dimension = max(640, dimension / 2)
        }

        throw BrowsemiumError.captureFailed("The page snapshot is too large to share.")
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static func downscaled(_ image: CGImage, maxDimension: Int) throws -> CGImage {
        let width = image.width
        let height = image.height
        let longest = max(width, height)
        guard longest > maxDimension else { return image }

        let scale = Double(maxDimension) / Double(longest)
        let targetWidth = max(1, Int((Double(width) * scale).rounded()))
        let targetHeight = max(1, Int((Double(height) * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw BrowsemiumError.captureFailed("The page snapshot could not be resized.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let result = context.makeImage() else {
            throw BrowsemiumError.captureFailed("The page snapshot could not be resized.")
        }
        return result
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let representation = NSBitmapImageRep(cgImage: image)
        return representation.representation(using: .png, properties: [:])
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let representation = NSBitmapImageRep(cgImage: image)
        return representation.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
