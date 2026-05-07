import Foundation

/// The verdict from `classify_image_relevance`.
struct RelevanceVerdict: Codable, Equatable {
    var isDesign: Bool
    var confidence: Double
    var reason: String
    var looksLikeBrowser: Bool

    enum CodingKeys: String, CodingKey {
        case isDesign = "is_design"
        case confidence
        case reason
        case looksLikeBrowser = "looks_like_browser"
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

/// The merged record produced by the agent for a single screenshot.
struct ScreenshotRecord: Codable, Equatable {
    var filePath: String
    var capturedAt: Date
    var indexedAt: Date

    var relevance: RelevanceVerdict
    var metadata: DesignMetadata?
    var palette: ColorPalette?
    var visibleURL: VisibleURL?
}

/// Errors emitted by the agent / Ollama client.
enum RefVaultError: Error, LocalizedError {
    case ollamaUnreachable(String)
    case ollamaHTTPError(Int, String)
    case modelOutputNotJSON(String)
    case promptResourceMissing(String)
    case imageReadFailed(URL)

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
        }
    }
}
