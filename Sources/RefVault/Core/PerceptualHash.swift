import Foundation
import AppKit
import CryptoKit

/// Two cheap dedup signatures for screenshots:
///
/// - `sha256(_:)` — exact byte hash. Catches "same file dropped from a
///   different path / re-imported / auto-numbered by macOS." ~10ms.
/// - `dHash(_:)` — perceptual difference hash with the top region masked
///   off (so browser chrome diffs don't break dedup). 64-bit signature;
///   compare with `hammingDistance`. ~30ms.
///
/// SHA hits are exact and free if you have them; dHash catches near-dupes
/// that SHA misses (mid-animation frame, different tabs open, recompressed
/// version of the same screenshot).
enum PerceptualHash {

    // MARK: SHA-256

    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: dHash (perceptual difference hash)

    /// Compute a 64-bit difference hash. The image is optionally cropped at
    /// the top by `maskTopFraction` (defaults to 12% — empirically covers
    /// macOS / Chrome / Safari chrome on a Retina screenshot), then
    /// downscaled to a 9×8 grayscale grid. For each of the 8 rows we
    /// compare pixel[col] vs pixel[col+1]; 1 if right is brighter, 0
    /// otherwise. 8 comparisons × 8 rows = 64 bits.
    ///
    /// dHash is robust to: brightness shifts, mild compression, scaling,
    /// small color shifts, and (with the top mask) browser-chrome diffs.
    /// It IS sensitive to large layout changes — a redesigned page should
    /// not collide with the original.
    static func dHash(of url: URL, maskTopFraction: Double = 0.12) -> UInt64? {
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        guard let cg = nsImage.cgImage(
            forProposedRect: nil, context: nil, hints: nil
        ) else { return nil }

        // Crop top
        let totalH = CGFloat(cg.height)
        let totalW = CGFloat(cg.width)
        let cropFrac = max(0, min(0.4, CGFloat(maskTopFraction)))
        let cropTop = floor(totalH * cropFrac)
        let cropRect = CGRect(
            x: 0,
            y: cropTop,
            width: totalW,
            height: max(1, totalH - cropTop)
        )
        let working = cg.cropping(to: cropRect) ?? cg

        // Downscale to 9×8 grayscale via a CGBitmapContext. The buffer
        // pointer passed to CGContext must remain valid for the lifetime
        // of the draw call, so the create + draw + read sequence has to
        // live inside one withUnsafeMutableBytes closure (otherwise the
        // pointer would dangle after the closure returns and the draw
        // would corrupt unrelated memory).
        let outW = 9
        let outH = 8
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: outW * outH)
        let ok: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: outW,
                height: outH,
                bitsPerComponent: 8,
                bytesPerRow: outW,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(working, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            return true
        }
        guard ok else { return nil }

        // Build the 64-bit hash: row-major, 8 comparisons per row.
        var hash: UInt64 = 0
        var bit: UInt64 = 1
        for row in 0..<outH {
            let rowStart = row * outW
            for col in 0..<(outW - 1) {
                let left = pixels[rowStart + col]
                let right = pixels[rowStart + col + 1]
                if right > left { hash |= bit }
                bit <<= 1
            }
        }
        return hash
    }

    // MARK: Comparison

    /// Number of differing bits between two 64-bit hashes. 0 = identical,
    /// 64 = inverted. Threshold for "same image" is typically 4-8 bits
    /// depending on how lenient you want to be.
    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}
