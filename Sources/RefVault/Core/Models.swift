import Foundation

/// The verdict from `classify_image_relevance`.
struct RelevanceVerdict: Codable, Equatable {
    var isDesign: Bool
    var confidence: Double
    var reason: String
    var looksLikeBrowser: Bool
    /// "website" | "app" | "poster" | "illustration" | "document" | "other"
    var surface: String
    /// "desktop" | "mobile" | "tablet" | "other"
    var device: String

    enum CodingKeys: String, CodingKey {
        case isDesign = "is_design"
        case confidence
        case reason
        case looksLikeBrowser = "looks_like_browser"
        case surface
        case device
    }

    init(
        isDesign: Bool,
        confidence: Double,
        reason: String,
        looksLikeBrowser: Bool,
        surface: String,
        device: String
    ) {
        self.isDesign = isDesign
        self.confidence = confidence
        self.reason = reason
        self.looksLikeBrowser = looksLikeBrowser
        self.surface = surface
        self.device = device
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.isDesign = try c.decode(Bool.self, forKey: .isDesign)
        self.confidence = try c.decode(Double.self, forKey: .confidence)
        self.reason = try c.decode(String.self, forKey: .reason)
        self.looksLikeBrowser = (try? c.decode(Bool.self, forKey: .looksLikeBrowser)) ?? false
        self.surface = (try? c.decode(String.self, forKey: .surface)) ?? "other"
        self.device = (try? c.decode(String.self, forKey: .device)) ?? "other"
    }
}

/// The output of `extract_design_metadata`.
struct DesignMetadata: Codable, Equatable {
    var style: String
    var typography: String
    var layout: String
    var mood: String
    var tags: [String]
}

/// The output of `extract_color_palette`.
struct ColorPalette: Codable, Equatable {
    var primary: String
    var secondary: String
    var accent: String
    var all: [String]
}

/// The output of `extract_visible_url`.
struct VisibleURL: Codable, Equatable {
    var url: String?
    var foundIn: String?

    enum CodingKeys: String, CodingKey {
        case url
        case foundIn = "found_in"
    }
}

/// The raw result of one agent run, before it is persisted to the library.
struct AgentResult: Equatable {
    var relevance: RelevanceVerdict
    var metadata: DesignMetadata?
    var palette: ColorPalette?
    var visibleURL: VisibleURL?
}

/// One persisted screenshot in the local library.
struct ScreenshotRecord: Codable, Equatable, Identifiable {
    var id: UUID
    /// Original path on disk (used for dedupe + traceability).
    var sourceFilePath: String
    /// Filename inside the library's images/ directory if a copy was kept.
    var storedFileName: String?
    var capturedAt: Date
    var indexedAt: Date
    var imageWidth: Int
    var imageHeight: Int

    var relevance: RelevanceVerdict
    var metadata: DesignMetadata?
    var palette: ColorPalette?
    var visibleURL: VisibleURL?

    /// Computed from pixel dimensions; not asked of the model.
    var orientation: String {
        guard imageWidth > 0, imageHeight > 0 else { return "unknown" }
        let ratio = Double(imageWidth) / Double(imageHeight)
        if ratio > 1.15 { return "landscape" }
        if ratio < 0.85 { return "portrait" }
        return "square"
    }
}

/// Errors emitted by the agent / Ollama client / library.
enum RefVaultError: Error, LocalizedError {
    case ollamaUnreachable(String)
    case ollamaHTTPError(Int, String)
    case modelOutputNotJSON(String)
    case promptResourceMissing(String)
    case imageReadFailed(URL)
    case libraryWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .ollamaUnreachable(let why):
            return "Ollama is unreachable: \(why)"
        case .ollamaHTTPError(let code, let body):
            return "Ollama HTTP \(code): \(body)"
        case .modelOutputNotJSON(let raw):
            return "Model output was not valid JSON. Raw: \(raw.prefix(400))"
        case .promptResourceMissing(let name):
            return "Missing prompt resource: \(name)"
        case .imageReadFailed(let url):
            return "Could not read image at \(url.path)"
        case .libraryWriteFailed(let why):
            return "Library write failed: \(why)"
        }
    }
}
