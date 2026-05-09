import Foundation

/// Maps hex colors to coarse human-readable family names. Deliberately
/// fuzzy — "brown" returns the family for light, mid, and dark browns —
/// because the user wants "search for brown" to surface every brown.
///
/// Algorithm: convert hex → HSL, then bucket by lightness/saturation/hue.
/// No external dataset, no Lab nearest-neighbor; this is a 12-bucket
/// classifier tuned for typical UI palettes.
enum ColorNamer {
    static let allFamilies: [String] = [
        "black", "white", "gray", "red", "orange", "yellow", "green",
        "teal", "blue", "purple", "pink", "brown", "beige"
    ]

    /// The single best family label for a hex string. Returns "unknown"
    /// for malformed input.
    static func family(for hex: String) -> String {
        guard let (r, g, b) = rgbComponents(hex) else { return "unknown" }
        let (h, s, l) = rgbToHSL(r: r, g: g, b: b)

        // Perceptual distance to white / black catches off-whites like
        // #EBEBE4 (HSL saturation gets misleadingly high near the corners
        // of the color cube — a small color tilt blows up s but the eye
        // still reads it as white). Distance ≤ 0.18 ≈ "looks white"; same
        // for black.
        let distFromWhite = sqrt(pow(1 - r, 2) + pow(1 - g, 2) + pow(1 - b, 2))
        if distFromWhite < 0.18 { return "white" }
        let distFromBlack = sqrt(r * r + g * g + b * b)
        if distFromBlack < 0.20 { return "black" }

        if s < 0.10 { return "gray" }

        // Browns sit in the warm hue range with low-to-mid lightness.
        let warmHue = h < 50 || h >= 350
        if warmHue && l < 0.50 && s >= 0.12 { return "brown" }

        // Beige / cream: warm hue, high lightness, modest saturation.
        if h < 60 && l > 0.70 && s < 0.55 { return "beige" }

        switch h {
        case 0..<15, 350..<360:  return "red"
        case 15..<45:             return "orange"
        case 45..<65:             return "yellow"
        case 65..<170:            return "green"
        case 170..<200:           return "teal"
        case 200..<255:           return "blue"
        case 255..<295:           return "purple"
        case 295..<335:           return "pink"
        case 335..<350:           return "red"
        default:                   return "unknown"
        }
    }

    /// Every family name a hex hits. Edge hexes that sit near a bucket boundary
    /// (e.g. teal-leaning blues) report both — keeps the search fuzzy.
    static func families(for hex: String) -> [String] {
        guard let (r, g, b) = rgbComponents(hex) else { return [] }
        let (h, s, l) = rgbToHSL(r: r, g: g, b: b)
        var fams: Set<String> = [family(for: hex)]

        let distFromWhite = sqrt(pow(1 - r, 2) + pow(1 - g, 2) + pow(1 - b, 2))
        let distFromBlack = sqrt(r * r + g * g + b * b)
        // Off-whites (cream, paper) also surface for "white" search.
        if distFromWhite < 0.25 { fams.insert("white") }
        if distFromBlack < 0.28 { fams.insert("black") }
        // Near-neutrals also count as gray.
        if s < 0.18, l >= 0.10, l <= 0.92 { fams.insert("gray") }
        // Warm dark hues also count as brown.
        if (h < 50 || h >= 340) && l < 0.55 && s >= 0.10 { fams.insert("brown") }
        // Light warm hues also count as beige.
        if h < 60 && l > 0.65 && s < 0.6 { fams.insert("beige") }

        fams.remove("unknown")
        return Array(fams)
    }

    /// Pretty label combining family + hex, used in the detail view.
    static func label(for hex: String) -> String {
        let fam = family(for: hex)
        return fam == "unknown" ? hex : "\(fam) · \(hex)"
    }

    // MARK: - Color-space helpers

    private static func rgbComponents(_ hex: String) -> (Double, Double, Double)? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (
            Double((v >> 16) & 0xff) / 255,
            Double((v >> 8) & 0xff) / 255,
            Double(v & 0xff) / 255
        )
    }

    private static func rgbToHSL(
        r: Double, g: Double, b: Double
    ) -> (h: Double, s: Double, l: Double) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let l = (maxC + minC) / 2
        let d = maxC - minC
        if d < 0.0001 { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        var h: Double = 0
        if maxC == r {
            h = ((g - b) / d).truncatingRemainder(dividingBy: 6)
        } else if maxC == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        return (h, s, l)
    }
}
