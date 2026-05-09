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
        self.confidenceThreshold = stored ?? 0.95

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

    /// Cheap exact-match dedup: returns the record whose `fileHash` equals
    /// the given SHA-256, if any. Catches "same file at a different path."
    func findExactDuplicate(sha: String) -> ScreenshotRecord? {
        records.first(where: { $0.fileHash == sha })
    }

    /// Visual dedup: returns the closest record whose `perceptualHash` is
    /// within `threshold` Hamming bits of `phash`. Returns nil if nothing
    /// is close enough or no records have a perceptual hash yet.
    /// Threshold default 6 — see PerceptualHash.dHash documentation.
    func findVisualDuplicate(
        phash: UInt64,
        threshold: Int = 6
    ) -> (record: ScreenshotRecord, hamming: Int)? {
        findVisualDuplicates(phash: phash, threshold: threshold).first
    }

    /// All records within Hamming `threshold`, sorted nearest-first.
    /// Used by the duplicate toast which shows the new image highlighted
    /// alongside every existing reference it matched.
    func findVisualDuplicates(
        phash: UInt64,
        threshold: Int = 6
    ) -> [(record: ScreenshotRecord, hamming: Int)] {
        var out: [(ScreenshotRecord, Int)] = []
        for r in records {
            guard let existing = r.perceptualHash else { continue }
            let d = PerceptualHash.hammingDistance(existing, phash)
            if d <= threshold {
                out.append((r, d))
            }
        }
        return out
            .sorted { $0.1 < $1.1 }
            .map { (record: $0.0, hamming: $0.1) }
    }

    /// Compute SHA + dHash for any record that's missing them. Fixes the
    /// "uploaded the same image but dedup didn't catch it" problem caused
    /// by records persisted before the dedup feature shipped — they
    /// decoded with nil hashes, so the duplicate check found nothing to
    /// match against. Runs on a background task at startup; persists once
    /// at the end so we're not writing the JSON N times.
    func backfillHashesIfNeeded() async {
        let need = records.filter { $0.fileHash == nil || $0.perceptualHash == nil }
        guard !need.isEmpty else {
            FileHandle.standardError.write(Data(
                "[Library] backfill: all \(records.count) records already have hashes\n".utf8
            ))
            return
        }
        FileHandle.standardError.write(Data(
            "[Library] backfill: computing hashes for \(need.count) of \(records.count) records\n".utf8
        ))

        // Snapshot the (id, url) pairs and compute hashes off the main
        // actor so we don't block UI for ~30ms × N records.
        let work: [(UUID, URL)] = need.compactMap { rec in
            guard let url = storedImageURL(for: rec) else { return nil }
            return (rec.id, url)
        }
        let results: [(UUID, String?, UInt64?)] = await Task.detached(priority: .utility) {
            work.map { id, url in
                let sha = PerceptualHash.sha256(of: url)
                let phash = PerceptualHash.dHash(of: url)
                return (id, sha, phash)
            }
        }.value

        // Apply results back on the main actor.
        var changed = 0
        for (id, sha, phash) in results {
            guard let idx = records.firstIndex(where: { $0.id == id }) else { continue }
            if records[idx].fileHash == nil, let sha {
                records[idx].fileHash = sha
                changed += 1
            }
            if records[idx].perceptualHash == nil, let phash {
                records[idx].perceptualHash = phash
                changed += 1
            }
        }
        if changed > 0 {
            persist()
        }
        FileHandle.standardError.write(Data(
            "[Library] backfill: done, updated \(changed) field(s)\n".utf8
        ))
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
    /// `processingSeconds` is the wall-clock time the agent took to produce
    /// `result` — captured by the coordinator and stored on the record so
    /// the detail view can show "Indexed in 8.2s".
    @discardableResult
    func saveRecord(
        from result: AgentResult,
        sourceURL: URL,
        processingSeconds: Double? = nil,
        fileHash: String? = nil,
        perceptualHash: UInt64? = nil
    ) -> ScreenshotRecord? {
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
            visibleURL: result.visibleURL,
            processingSeconds: processingSeconds,
            fileHash: fileHash,
            perceptualHash: perceptualHash
        )
        records.insert(record, at: 0)
        persist()
        return record
    }

    /// Replace an existing record's agent-derived fields (relevance, metadata,
    /// palette, URL). Keeps id, file paths, and capture/index dates. Used by
    /// the debug regenerate flow.
    @discardableResult
    func update(
        record: ScreenshotRecord,
        with result: AgentResult,
        processingSeconds: Double? = nil,
        fileHash: String? = nil,
        perceptualHash: UInt64? = nil
    ) -> ScreenshotRecord? {
        guard let idx = records.firstIndex(where: { $0.id == record.id }) else {
            return nil
        }
        var updated = records[idx]
        updated.relevance = result.relevance
        updated.metadata = result.metadata
        updated.palette = result.palette
        updated.visibleURL = result.visibleURL
        updated.indexedAt = Date()
        if let s = processingSeconds {
            updated.processingSeconds = s
        }
        // Backfill hashes only when caller supplied them (regenerate path
        // computes them; old records had nil before dedup landed and get
        // a value the next time they're regenerated).
        if let fh = fileHash {
            updated.fileHash = fh
        }
        if let ph = perceptualHash {
            updated.perceptualHash = ph
        }
        records[idx] = updated
        persist()
        return updated
    }

    func delete(_ record: ScreenshotRecord) {
        if let url = storedImageURL(for: record) {
            try? FileManager.default.removeItem(at: url)
        }
        records.removeAll(where: { $0.id == record.id })
        persist()
    }

    /// Distinct values seen across the library, ordered by frequency (most
    /// common first). Fed into the search prompt so Gemma maps free-text
    /// queries onto values that *actually exist* in the library, instead of
    /// inventing close-but-wrong synonyms ("editorial" vs "magazine-style").
    var vocabulary: LibraryVocabulary {
        var styleHits: [String: Int] = [:]
        var moodHits: [String: Int] = [:]
        var layoutHits: [String: Int] = [:]
        var tagHits: [String: Int] = [:]
        var surfaceHits: [String: Int] = [:]
        var deviceHits: [String: Int] = [:]

        for r in records {
            let s = r.relevance.surface.lowercased()
            if !s.isEmpty { surfaceHits[s, default: 0] += 1 }
            let d = r.relevance.device.lowercased()
            if !d.isEmpty { deviceHits[d, default: 0] += 1 }
            guard let m = r.metadata else { continue }
            if !m.style.isEmpty { styleHits[m.style.lowercased(), default: 0] += 1 }
            if !m.mood.isEmpty { moodHits[m.mood.lowercased(), default: 0] += 1 }
            if !m.layout.isEmpty { layoutHits[m.layout.lowercased(), default: 0] += 1 }
            for t in m.tags where !t.isEmpty {
                tagHits[t.lowercased(), default: 0] += 1
            }
        }

        func sorted(_ d: [String: Int], cap: Int) -> [String] {
            d.sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(cap)
            .map { $0.key }
        }

        return LibraryVocabulary(
            styles: sorted(styleHits, cap: 80),
            moods: sorted(moodHits, cap: 80),
            layouts: sorted(layoutHits, cap: 80),
            tags: sorted(tagHits, cap: 200),
            surfaces: sorted(surfaceHits, cap: 20),
            devices: sorted(deviceHits, cap: 10)
        )
    }

    /// Unified pool of attributes shown as flat chips in the library /
    /// popover tags row — style, mood, layout, tags, surface, device,
    /// orientation. Typography lives in its own dropdown menu, color in
    /// its own picker; both excluded here. De-duplicated, lowercased,
    /// ranked by frequency. Filtering happens via `chipHaystack(for:)`,
    /// which matches all of these attributes.
    var chipVocabulary: [String] {
        var hits: [String: Int] = [:]
        for r in records {
            let s = r.relevance.surface.lowercased()
            if !s.isEmpty { hits[s, default: 0] += 1 }
            let d = r.relevance.device.lowercased()
            if !d.isEmpty { hits[d, default: 0] += 1 }
            let o = r.orientation.lowercased()
            if !o.isEmpty { hits[o, default: 0] += 1 }
            guard let m = r.metadata else { continue }
            if !m.style.isEmpty { hits[m.style.lowercased(), default: 0] += 1 }
            if !m.mood.isEmpty { hits[m.mood.lowercased(), default: 0] += 1 }
            if !m.layout.isEmpty { hits[m.layout.lowercased(), default: 0] += 1 }
            for t in m.tags where !t.isEmpty {
                hits[t.lowercased(), default: 0] += 1
            }
        }
        return hits.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }.map { $0.key }
    }

    /// Typography fonts grouped by their record-level slot (heading /
    /// body / other). Each section is de-duplicated and ranked by
    /// frequency. Drives the typography dropdown that mirrors the color
    /// picker.
    struct TypographyVocabulary {
        var headings: [String]
        var bodies: [String]
        var others: [String]
        var isEmpty: Bool { headings.isEmpty && bodies.isEmpty && others.isEmpty }
    }
    var typographyVocabulary: TypographyVocabulary {
        var headHits: [String: Int] = [:]
        var bodyHits: [String: Int] = [:]
        var otherHits: [String: Int] = [:]
        for r in records {
            guard let m = r.metadata else { continue }
            for f in m.typography.headings where !f.isEmpty {
                headHits[f, default: 0] += 1
            }
            for f in m.typography.bodies where !f.isEmpty {
                bodyHits[f, default: 0] += 1
            }
            for f in m.typography.others where !f.isEmpty {
                otherHits[f, default: 0] += 1
            }
        }
        func sorted(_ d: [String: Int]) -> [String] {
            d.sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }.map { $0.key }
        }
        return TypographyVocabulary(
            headings: sorted(headHits),
            bodies: sorted(bodyHits),
            others: sorted(otherHits)
        )
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

    /// Apply a Gemma-parsed structured filter. Each populated axis acts as
    /// an AND constraint; lists within a single axis are OR'd.
    func search(filter: SearchFilter) -> [ScreenshotRecord] {
        guard !filter.isEmpty else { return records }
        return records.filter { rec in matches(rec, filter: filter) }
    }

    private func matches(_ rec: ScreenshotRecord, filter f: SearchFilter) -> Bool {
        if let surfaces = f.surfaces, !surfaces.isEmpty,
           !surfaces.map({ $0.lowercased() }).contains(rec.relevance.surface.lowercased()) {
            return false
        }
        if let devices = f.devices, !devices.isEmpty,
           !devices.map({ $0.lowercased() }).contains(rec.relevance.device.lowercased()) {
            return false
        }
        if let orientations = f.orientations, !orientations.isEmpty,
           !orientations.map({ $0.lowercased() }).contains(rec.orientation.lowercased()) {
            return false
        }
        if let styles = f.styles, !styles.isEmpty {
            let s = rec.metadata?.style.lowercased() ?? ""
            if !styles.contains(where: { s.contains($0.lowercased()) }) { return false }
        }
        if let moods = f.moods, !moods.isEmpty {
            let m = rec.metadata?.mood.lowercased() ?? ""
            if !moods.contains(where: { m.contains($0.lowercased()) }) { return false }
        }
        let recTags = Set((rec.metadata?.tags ?? []).map { $0.lowercased() })
        if let all = f.tagsAll, !all.isEmpty {
            let needed = all.map { $0.lowercased() }
            if !needed.allSatisfy({ recTags.contains($0) }) { return false }
        }
        if let any = f.tagsAny, !any.isEmpty {
            let candidates = any.map { $0.lowercased() }
            var extended = recTags
                .union([rec.metadata?.style, rec.metadata?.mood, rec.metadata?.layout]
                    .compactMap { $0?.lowercased() })
            for term in rec.metadata?.typography.allTerms ?? [] {
                extended.insert(term.lowercased())
            }
            if !candidates.contains(where: { extended.contains($0) }) { return false }
        }
        if let colors = f.colors, !colors.isEmpty {
            if !colorMatches(rec, terms: colors) { return false }
        }
        if let free = f.freeText?.trimmingCharacters(in: .whitespaces), !free.isEmpty {
            let haystack = haystackString(for: rec)
            let terms = free.lowercased().split(separator: " ").map(String.init)
            if !terms.allSatisfy({ haystack.contains($0) }) { return false }
        }
        return true
    }

    private func colorMatches(_ rec: ScreenshotRecord, terms: [String]) -> Bool {
        let palette = rec.palette?.all ?? []
        guard !palette.isEmpty else { return false }
        // Fuzzy color-family lookup: "brown" matches light/mid/dark browns.
        let paletteFamilies: Set<String> = palette.reduce(into: []) { acc, hex in
            for f in ColorNamer.families(for: hex) { acc.insert(f) }
        }
        for term in terms.map({ $0.lowercased() }) {
            if term.hasPrefix("#") {
                if palette.contains(where: { $0.lowercased() == term }) { return true }
                continue
            }
            switch term {
            case "dark":
                if palette.contains(where: { paletteIsDark($0) }) { return true }
            case "light":
                if palette.contains(where: { paletteIsLight($0) }) { return true }
            case "warm":
                if palette.contains(where: { paletteIsWarm($0) }) { return true }
            case "cool":
                if palette.contains(where: { paletteIsCool($0) }) { return true }
            default:
                if paletteFamilies.contains(term) { return true }
                // Last resort: substring against the palette / mood string.
                let hay = (palette + [rec.metadata?.mood ?? ""])
                    .joined(separator: " ").lowercased()
                if hay.contains(term) { return true }
            }
        }
        return false
    }

    private func rgbComponents(_ hex: String) -> (Double, Double, Double)? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (
            Double((v >> 16) & 0xff) / 255,
            Double((v >> 8) & 0xff) / 255,
            Double(v & 0xff) / 255
        )
    }

    private func luminance(_ hex: String) -> Double? {
        guard let (r, g, b) = rgbComponents(hex) else { return nil }
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private func paletteIsDark(_ hex: String) -> Bool {
        (luminance(hex) ?? 1) < 0.25
    }

    private func paletteIsLight(_ hex: String) -> Bool {
        (luminance(hex) ?? 0) > 0.75
    }

    private func paletteIsWarm(_ hex: String) -> Bool {
        guard let (r, _, b) = rgbComponents(hex) else { return false }
        return r - b > 0.10
    }

    private func paletteIsCool(_ hex: String) -> Bool {
        guard let (r, _, b) = rgbComponents(hex) else { return false }
        return b - r > 0.10
    }

    private func haystackString(for rec: ScreenshotRecord) -> String {
        var parts: [String] = [
            rec.relevance.surface,
            rec.relevance.device,
            rec.relevance.reason,
            rec.orientation
        ]
        if let m = rec.metadata {
            parts.append(contentsOf: [m.style, m.layout, m.mood])
            parts.append(contentsOf: m.typography.allTerms)
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
