import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Loads an image from disk, downscales to the given long-edge size,
/// and returns it as a base64 JPEG string ready for Ollama.
///
/// Retina screenshots are huge — 1024px on the long edge keeps Gemma fast
/// without degrading visual semantics for tagging.
enum ImageEncoder {
    static func loadAndEncode(
        from url: URL,
        longEdge: CGFloat = 1024,
        jpegQuality: CGFloat = 0.85
    ) throws -> String {
        #if canImport(AppKit)
        guard let original = NSImage(contentsOf: url) else {
            throw RefVaultError.imageReadFailed(url)
        }
        let resized = downscale(original, longEdge: longEdge)
        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(
                using: .jpeg,
                properties: [.compressionFactor: jpegQuality]
              )
        else {
            throw RefVaultError.imageReadFailed(url)
        }
        return jpeg.base64EncodedString()
        #else
        let data = try Data(contentsOf: url)
        return data.base64EncodedString()
        #endif
    }

    #if canImport(AppKit)
    private static func downscale(_ image: NSImage, longEdge: CGFloat) -> NSImage {
        let size = image.size
        let maxDim = max(size.width, size.height)
        guard maxDim > longEdge else { return image }
        let scale = longEdge / maxDim
        let newSize = NSSize(
            width: floor(size.width * scale),
            height: floor(size.height * scale)
        )
        let resized = NSImage(size: newSize)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1.0
        )
        resized.unlockFocus()
        return resized
    }
    #endif
}
