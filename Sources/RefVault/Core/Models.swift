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

/// Typography is a multi-axis field — a single screenshot often pairs a
/// display heading face with a separate body face. Records before this
/// structure decode the legacy string into `others`.
struct Typography: Codable, Equatable {
    var headings: [String]
    var bodies: [String]
    var others: [String]

    init(headings: [String] = [], bodies: [String] = [], others: [String] = []) {
        self.headings = headings
        self.bodies = bodies
        self.others = others
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.headings = (try? c.decode([String].self, forKey: .headings)) ?? []
        self.bodies = (try? c.decode([String].self, forKey: .bodies)) ?? []
        self.others = (try? c.decode([String].self, forKey: .others)) ?? []
    }

    enum CodingKeys: String, CodingKey { case headings, bodies, others }

    var isEmpty: Bool {
        headings.isEmpty && bodies.isEmpty && others.isEmpty
    }

    /// Flat list of every term in any of the three axes — used for search.
    var allTerms: [String] {
        headings + bodies + others
    }
}

/// The output of `extract_design_metadata`.
struct DesignMetadata: Equatable {
    var style: String
    var typography: Typography
    var layout: String
    var mood: String
    var tags: [String]
}

extension DesignMetadata: Codable {
    enum CodingKeys: String, CodingKey {
        case style, typography, layout, mood, tags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.style = (try? c.decode(String.self, forKey: .style)) ?? ""
        self.layout = (try? c.decode(String.self, forKey: .layout)) ?? ""
        self.mood = (try? c.decode(String.self, forKey: .mood)) ?? ""
        self.tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        // Typography accepts either the new object shape or a legacy string.
        if let typ = try? c.decode(Typography.self, forKey: .typography) {
            self.typography = typ
        } else if let str = try? c.decode(String.self, forKey: .typography),
                  !str.trimmingCharacters(in: .whitespaces).isEmpty {
            self.typography = Typography(others: [str])
        } else {
            self.typography = Typography()
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(style, forKey: .style)
        try c.encode(typography, forKey: .typography)
        try c.encode(layout, forKey: .layout)
        try c.encode(mood, forKey: .mood)
        try c.encode(tags, forKey: .tags)
    }
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
struct ScreenshotRecord: Equatable, Identifiable {
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

    /// Wall-clock seconds the agent took to produce this record's metadata.
    /// Optional because pre-existing library entries (saved before the
    /// timing field existed) decode with `nil` and are filled on next regen.
    var processingSeconds: Double?

    /// Computed from pixel dimensions; not asked of the model.
    var orientation: String {
        guard imageWidth > 0, imageHeight > 0 else { return "unknown" }
        let ratio = Double(imageWidth) / Double(imageHeight)
        if ratio > 1.15 { return "landscape" }
        if ratio < 0.85 { return "portrait" }
        return "square"
    }

    init(
        id: UUID,
        sourceFilePath: String,
        storedFileName: String?,
        capturedAt: Date,
        indexedAt: Date,
        imageWidth: Int,
        imageHeight: Int,
        relevance: RelevanceVerdict,
        metadata: DesignMetadata?,
        palette: ColorPalette?,
        visibleURL: VisibleURL?,
        processingSeconds: Double? = nil
    ) {
        self.id = id
        self.sourceFilePath = sourceFilePath
        self.storedFileName = storedFileName
        self.capturedAt = capturedAt
        self.indexedAt = indexedAt
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.relevance = relevance
        self.metadata = metadata
        self.palette = palette
        self.visibleURL = visibleURL
        self.processingSeconds = processingSeconds
    }
}

extension ScreenshotRecord: Codable {
    enum CodingKeys: String, CodingKey {
        case id, sourceFilePath, storedFileName, capturedAt, indexedAt
        case imageWidth, imageHeight
        case relevance, metadata, palette, visibleURL
        case processingSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.sourceFilePath = try c.decode(String.self, forKey: .sourceFilePath)
        self.storedFileName = try? c.decode(String.self, forKey: .storedFileName)
        self.capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        self.indexedAt = try c.decode(Date.self, forKey: .indexedAt)
        self.imageWidth = try c.decode(Int.self, forKey: .imageWidth)
        self.imageHeight = try c.decode(Int.self, forKey: .imageHeight)
        self.relevance = try c.decode(RelevanceVerdict.self, forKey: .relevance)
        self.metadata = try? c.decode(DesignMetadata.self, forKey: .metadata)
        self.palette = try? c.decode(ColorPalette.self, forKey: .palette)
        self.visibleURL = try? c.decode(VisibleURL.self, forKey: .visibleURL)
        // processingSeconds is optional and was added later — older library
        // entries simply decode it as nil.
        self.processingSeconds = try? c.decode(Double.self, forKey: .processingSeconds)
    }
}

/// Structured filter parsed from a natural-language search query by Gemma.
/// Every field is optional; `nil` or `[]` means "no constraint on this axis".
struct SearchFilter: Codable, Equatable {
    /// Surfaces the query is interested in (website / app / poster / …).
    var surfaces: [String]?
    /// Devices (desktop / mobile / tablet).
    var devices: [String]?
    /// Orientations (landscape / portrait / square).
    var orientations: [String]?
    /// Style adjectives (minimal, brutalist, editorial, …).
    var styles: [String]?
    /// Mood adjectives (calm, energetic, …).
    var moods: [String]?
    /// Tags that must all be present.
    var tagsAll: [String]?
    /// Tags where at least one must be present.
    var tagsAny: [String]?
    /// Color descriptors — "dark", "warm", or hex strings.
    var colors: [String]?
    /// Anything Gemma couldn't fit in a structured field — applied as
    /// substring match across the haystack.
    var freeText: String?

    enum CodingKeys: String, CodingKey {
        case surfaces, devices, orientations, styles, moods, colors
        case tagsAll = "tags_all"
        case tagsAny = "tags_any"
        case freeText = "free_text"
    }

    var isEmpty: Bool {
        let lists: [[String]?] = [
            surfaces, devices, orientations, styles, moods, tagsAll, tagsAny, colors
        ]
        let anyList = lists.contains { ($0 ?? []).isEmpty == false }
        let hasFree = (freeText ?? "").trimmingCharacters(in: .whitespaces).isEmpty == false
        return !anyList && !hasFree
    }
}

/// Aggregate of distinct field values seen across the library. Passed to the
/// search parser so Gemma snaps free-text queries onto values that exist in
/// the library, rather than inventing close-but-wrong synonyms.
struct LibraryVocabulary {
    var styles: [String]
    var moods: [String]
    var layouts: [String]
    var tags: [String]
    var surfaces: [String]
    var devices: [String]

    var isEmpty: Bool {
        styles.isEmpty && moods.isEmpty && layouts.isEmpty
            && tags.isEmpty && surfaces.isEmpty && devices.isEmpty
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
