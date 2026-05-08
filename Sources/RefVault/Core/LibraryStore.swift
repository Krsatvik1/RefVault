import Foundation
import AppKit

/// The local library: a list of saved screenshot records plus the copied
/// image files they reference. Persists to:
///   ~/Library/Application Support/RefVault/library.json
///   ~/Library/Application Support/RefVault/images/<uuid>.<ext>
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var records: [ScreenshotRecord] = []
    @Published var confidenceThreshold: Double {
        didSet { UserDefaults.standard.set(confidenceThreshold, forKey: Self.thresholdKey) }
    }
    @Published var lastError: String?

    private let libraryDir: URL
    private let imagesDir: URL
    private let libraryFile: URL

    private static let thresholdKey = "refvault.confidenceThreshold"

    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("RefVault", isDirectory: true)
        self.libraryDir = dir
        self.imagesDir = dir.appendingPathComponent("images", isDirectory: true)
        self.libraryFile = dir.appendingPathComponent("library.json")

        let stored = UserDefaults.standard.object(forKey: Self.thresholdKey) as? Double
        self.confidenceThreshold = stored ?? 0.5

        try? FileManager.default.createDirectory(
            at: imagesDir,
            withIntermediateDirectories: true
        )
        load()
    }

    // MARK: - Public API

    var imagesDirectory: URL { imagesDir }
    var libraryDirectory: URL { libraryDir }

    func contains(sourcePath: String) -> Bool {
        records.contains(where: { $0.sourceFilePath == sourcePath })
    }

    func storedImageURL(for record: ScreenshotRecord) -> URL? {
        guard let name = record.storedFileName else { return nil }
        return imagesDir.appendingPathComponent(name)
    }

    /// Whether an agent result is worth saving — design + confidence above
    /// the user-set threshold.
    func shouldKeep(_ result: AgentResult) -> Bool {
        result.relevance.isDesign &&
            result.relevance.confidence >= confidenceThreshold
    }

    /// Copy the source image into the library and persist a new record.
    @discardableResult
    func saveRecord(from result: AgentResult, sourceURL: URL) -> ScreenshotRecord? {
        let dimensions = imageDimensions(for: sourceURL)
        let storedFileName: String
        do {
            storedFileName = try copyImageIntoLibrary(sourceURL: sourceURL)
        } catch {
            lastError = "Failed to copy image: \(error.localizedDescription)"
            return nil
        }
        let captured = (try? FileManager.default
            .attributesOfItem(atPath: sourceURL.path)[.creationDate] as? Date) ?? Date()
        let record = ScreenshotRecord(
            id: UUID(),
            sourceFilePath: sourceURL.path,
            storedFileName: storedFileName,
            capturedAt: captured,
            indexedAt: Date(),
            imageWidth: dimensions.width,
            imageHeight: dimensions.height,
            relevance: result.relevance,
            metadata: result.metadata,
            palette: result.palette,
            visibleURL: result.visibleURL
        )
        records.insert(record, at: 0)
        persist()
        return record
    }

    func delete(_ record: ScreenshotRecord) {
        if let url = storedImageURL(for: record) {
            try? FileManager.default.removeItem(at: url)
        }
        records.removeAll(where: { $0.id == record.id })
        persist()
    }

    /// Filter records against a free-text query. Matches across tags, style,
    /// surface, device, mood, layout, and visible URL.
    func search(_ query: String) -> [ScreenshotRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return records }
        let terms = q.split(separator: " ").map(String.init)
        return records.filter { rec in
            let haystack = haystackString(for: rec)
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    private func haystackString(for rec: ScreenshotRecord) -> String {
        var parts: [String] = [
            rec.relevance.surface,
            rec.relevance.device,
            rec.relevance.reason,
            rec.orientation
        ]
        if let m = rec.metadata {
            parts.append(contentsOf: [m.style, m.typography, m.layout, m.mood])
            parts.append(contentsOf: m.tags)
        }
        if let url = rec.visibleURL?.url { parts.append(url) }
        if let p = rec.palette { parts.append(contentsOf: p.all) }
        return parts.joined(separator: " ").lowercased()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: libraryFile.path) else { return }
        do {
            let data = try Data(contentsOf: libraryFile)
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            records = try dec.decode([ScreenshotRecord].self, from: data)
        } catch {
            lastError = "Failed to load library: \(error.localizedDescription)"
        }
    }

    private func persist() {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            let data = try enc.encode(records)
            try data.write(to: libraryFile, options: .atomic)
        } catch {
            lastError = "Failed to save library: \(error.localizedDescription)"
        }
    }

    private func copyImageIntoLibrary(sourceURL: URL) throws -> String {
        let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
        let name = "\(UUID().uuidString).\(ext)"
        let dest = imagesDir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        return name
    }

    private func imageDimensions(for url: URL) -> (width: Int, height: Int) {
        if let img = NSImage(contentsOf: url) {
            return (Int(img.size.width.rounded()), Int(img.size.height.rounded()))
        }
        return (0, 0)
    }
}
