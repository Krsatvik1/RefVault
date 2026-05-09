import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Loads an image from disk, downscales to the given long-edge size,
/// and returns it as a base64 JPEG string ready for Ollama.
///
/// Defaults to 3840px / 1.0 quality — empirically there's no material
/// per-call time difference between 1024 and 3840 on the 26b model,
/// so we default to "no downscale for any Retina screenshot up to
/// 14" Pro / 4K external" for the best vision fidelity. Callers that
/// care about wire size (none currently) can override.
enum ImageEncoder {
    static func loadAndEncode(
        from url: URL,
        longEdge: CGFloat = 3840,
        jpegQuality: CGFloat = 1.0,
        cropTopFraction: CGFloat = 0
    ) throws -> String {
        #if canImport(AppKit)
        guard let original = NSImage(contentsOf: url) else {
            throw RefVaultError.imageReadFailed(url)
        }
        let originalSize = pixelSize(original)

        // Optional top-of-image crop, used to chop browser chrome (address
        // bar / tabs) before metadata + palette analysis. Done in CGImage
        // space (top-left origin) to keep the math obvious. The reported
        // src dimensions stay the original screenshot — sent reflects the
        // post-crop, post-downscale payload.
        let cropFraction = max(0, min(0.4, cropTopFraction))
        let workingImage: NSImage
        let workingPixels: NSSize
        if cropFraction > 0,
           let cropped = topCropped(image: original, fractionFromTop: cropFraction) {
            workingImage = cropped
            workingPixels = pixelSize(cropped)
        } else {
            workingImage = original
            workingPixels = originalSize
        }

        let outRep = downscaleToPixels(
            workingImage,
            originalPixels: workingPixels,
            longEdgePixels: longEdge
        )
        let outW = outRep.pixelsWide
        let outH = outRep.pixelsHigh
        guard let jpeg = outRep.representation(
            using: .jpeg,
            properties: [.compressionFactor: jpegQuality]
        ) else {
            throw RefVaultError.imageReadFailed(url)
        }
        let srcW = Int(originalSize.width)
        let srcH = Int(originalSize.height)
        let jpegBytes = jpeg.count
        let base64Bytes = (jpegBytes * 4 + 2) / 3
        let cropNote = cropFraction > 0
            ? " crop-top=\(Int(cropFraction * 100))%"
            : ""
        let line = "[Image] \(url.lastPathComponent) src=\(srcW)×\(srcH)\(cropNote) → sent=\(outW)×\(outH) jpeg=\(jpegBytes)B base64=\(base64Bytes)B\n"
        FileHandle.standardError.write(Data(line.utf8))
        return jpeg.base64EncodedString()
        #else
        let data = try Data(contentsOf: url)
        return data.base64EncodedString()
        #endif
    }

    #if canImport(AppKit)
    /// Actual pixel dimensions, not point size. NSImage.size reports points
    /// (Retina @2x screenshots show as 1710×1107 pt instead of 3420×2214 px),
    /// so we read directly off the bitmap representation.
    private static func pixelSize(_ image: NSImage) -> NSSize {
        if let rep = image.representations.first as? NSBitmapImageRep {
            return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    /// Render `image` into a freshly-allocated `NSBitmapImageRep` whose
    /// pixel dimensions are explicitly clamped to `longEdgePixels`.
    ///
    /// Why we don't use `lockFocus` + `tiffRepresentation`: that path
    /// (a) compares against `NSImage.size` which is in *points*, so on
    /// Retina the cap silently doubled, and (b) re-rasters at the screen's
    /// backing scale, which can produce a bitmap larger than asked. Going
    /// directly through an explicit-pixel `NSBitmapImageRep` makes the
    /// output dimensions exactly what the slider says.
    /// Strip the top `fractionFromTop` of the image's pixel rows. Operates
    /// on the underlying `CGImage` in top-left coordinates so the math is
    /// unambiguous regardless of NSImage's bottom-up Cocoa convention.
    private static func topCropped(
        image: NSImage,
        fractionFromTop: CGFloat
    ) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let totalH = CGFloat(cg.height)
        let totalW = CGFloat(cg.width)
        let cropTop = floor(totalH * fractionFromTop)
        let keepH = totalH - cropTop
        guard keepH > 0 else { return nil }
        let rect = CGRect(x: 0, y: cropTop, width: totalW, height: keepH)
        guard let croppedCG = cg.cropping(to: rect) else { return nil }
        let result = NSImage(cgImage: croppedCG, size: NSSize(width: totalW, height: keepH))
        return result
    }

    private static func downscaleToPixels(
        _ image: NSImage,
        originalPixels: NSSize,
        longEdgePixels: CGFloat
    ) -> NSBitmapImageRep {
        let srcW = originalPixels.width
        let srcH = originalPixels.height
        let maxDim = max(srcW, srcH)

        let outW: Int
        let outH: Int
        if maxDim <= longEdgePixels {
            outW = Int(srcW)
            outH = Int(srcH)
        } else {
            let scale = longEdgePixels / maxDim
            outW = max(1, Int(floor(srcW * scale)))
            outH = max(1, Int(floor(srcH * scale)))
        }

        // If no resize and the existing rep is a bitmap, return it as-is
        // to skip the re-encode.
        if outW == Int(srcW), outH == Int(srcH),
           let firstRep = image.representations.first as? NSBitmapImageRep {
            return firstRep
        }

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: outW,
            pixelsHigh: outH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = NSSize(width: outW, height: outH)

        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = ctx
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: outW, height: outH),
            from: NSRect(x: 0, y: 0, width: srcW, height: srcH),
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    #endif
}
