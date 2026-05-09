import Foundation

/// The agentic loop that runs over a single screenshot.
///
/// Step 1 — relevance gate. If `is_design == false`, we exit early with a
/// minimal result. No further Ollama calls.
///
/// Step 2 — three extractors run in parallel: design metadata, color palette,
/// and (if the image looks like a browser) the visible URL. Independence is
/// what makes parallelism safe; Ollama on M-series Macs handles concurrent
/// requests without blowing up.
///
/// Step 3 — merge into one AgentResult and return. Persistence (file copy,
/// dimensions, ID assignment) is the caller's job.
struct GemmaAgent {
    var client: OllamaClient

    /// Streaming progress events the UI can subscribe to.
    enum Event {
        case startedRelevance
        case relevanceVerdict(RelevanceVerdict)
        case startedExtraction
        /// Granular mode only — fired before each per-field call lands.
        case fieldStarted(name: String)
        /// Granular mode only — fired when each per-field call returns.
        case field(name: String, snippet: String)
        case metadata(DesignMetadata)
        case palette(ColorPalette)
        case visibleURL(VisibleURL)
        case finished(AgentResult)
        case failed(Error, stage: String)
    }

    /// Runs the agent over an image at `url` and returns the merged result.
    /// `onEvent` lets callers render progress as the pipeline streams.
    /// Pass `model` to run against a model other than the agent's default.
    /// `granular: true` splits the metadata call into 5 per-field calls.
    /// `serial: true` (default) waits for each call to finish before the
    /// next; `serial: false` fans out via `async let`. Defaults to serial
    /// because Ollama's single-GPU inference is not actually faster under
    /// concurrency on most M-series Macs and parallel calls fight for the
    /// same KV cache.
    @discardableResult
    func run(
        imageAt url: URL,
        model: String? = nil,
        granular: Bool = false,
        serial: Bool = true,
        longEdge: CGFloat = 3840,
        jpegQuality: CGFloat = 1.0,
        urlModel: String? = OllamaClient.defaultURLModel,
        urlFirstFlow: Bool = false,
        onEvent: @escaping @Sendable (Event) -> Void = { _ in }
    ) async throws -> AgentResult {
        let fullImage = try ImageEncoder.loadAndEncode(
            from: url,
            longEdge: longEdge,
            jpegQuality: jpegQuality
        )
        let activeClient: OllamaClient = model.map { client.withModel($0) } ?? client
        // URL extraction can route to a separate (typically smaller) model
        // for faster OCR. Defaulted to OllamaClient.defaultURLModel; falls
        // back to the active client if nothing is specified.
        let urlClient: OllamaClient = urlModel.map { activeClient.withModel($0) } ?? activeClient

        if urlFirstFlow {
            return try await runURLFirstFlow(
                imageURL: url,
                fullImage: fullImage,
                longEdge: longEdge,
                jpegQuality: jpegQuality,
                granular: granular,
                serial: serial,
                activeClient: activeClient,
                urlClient: urlClient,
                onEvent: onEvent
            )
        } else {
            return try await runRelevanceFirstFlow(
                fullImage: fullImage,
                granular: granular,
                serial: serial,
                activeClient: activeClient,
                urlClient: urlClient,
                onEvent: onEvent
            )
        }
    }

    /// Original flow: relevance gate, then metadata + palette + url fan
    /// out together (URL only when relevance saw browser chrome). No image
    /// crop. URL still routes through `urlClient` so the smaller model gets
    /// the OCR work even in this flow.
    private func runRelevanceFirstFlow(
        fullImage: String,
        granular: Bool,
        serial: Bool,
        activeClient: OllamaClient,
        urlClient: OllamaClient,
        onEvent: @escaping @Sendable (Event) -> Void
    ) async throws -> AgentResult {
        onEvent(.startedRelevance)
        let relevance: RelevanceVerdict
        do {
            let prompt = try PromptStore.load("relevance")
            let (decoded, _) = try await activeClient.generateJSON(
                prompt: prompt,
                imageBase64: fullImage,
                as: RelevanceVerdict.self
            )
            relevance = decoded
        } catch {
            onEvent(.failed(error, stage: "relevance"))
            throw error
        }
        onEvent(.relevanceVerdict(relevance))

        guard relevance.isDesign else {
            let result = AgentResult(
                relevance: relevance,
                metadata: nil,
                palette: nil,
                visibleURL: nil
            )
            onEvent(.finished(result))
            return result
        }

        onEvent(.startedExtraction)
        let metadata: DesignMetadata?
        let palette: ColorPalette?
        let visibleURL: VisibleURL?
        if serial {
            metadata = granular
                ? await runMetadataGranular(
                    client: activeClient, imageBase64: fullImage,
                    serial: true, onEvent: onEvent)
                : await runMetadata(
                    client: activeClient, imageBase64: fullImage,
                    onEvent: onEvent)
            palette = await runPalette(
                client: activeClient, imageBase64: fullImage,
                onEvent: onEvent)
            visibleURL = relevance.looksLikeBrowser
                ? await runURL(
                    client: urlClient, imageBase64: fullImage,
                    onEvent: onEvent)
                : nil
        } else {
            async let m: DesignMetadata? = granular
                ? runMetadataGranular(
                    client: activeClient, imageBase64: fullImage,
                    serial: false, onEvent: onEvent)
                : runMetadata(
                    client: activeClient, imageBase64: fullImage,
                    onEvent: onEvent)
            async let p: ColorPalette? = runPalette(
                client: activeClient, imageBase64: fullImage,
                onEvent: onEvent)
            async let u: VisibleURL? = relevance.looksLikeBrowser
                ? runURL(
                    client: urlClient, imageBase64: fullImage,
                    onEvent: onEvent)
                : nil
            (metadata, palette, visibleURL) = await (m, p, u)
        }

        let result = AgentResult(
            relevance: relevance,
            metadata: metadata,
            palette: palette,
            visibleURL: visibleURL
        )
        onEvent(.finished(result))
        return result
    }

    /// URL-first flow: extract URL, crop top 12% of the image if URL came
    /// back (browser chrome detector), then run relevance + metadata +
    /// palette on the chrome-free image.
    private func runURLFirstFlow(
        imageURL: URL,
        fullImage: String,
        longEdge: CGFloat,
        jpegQuality: CGFloat,
        granular: Bool,
        serial: Bool,
        activeClient: OllamaClient,
        urlClient: OllamaClient,
        onEvent: @escaping @Sendable (Event) -> Void
    ) async throws -> AgentResult {
        onEvent(.startedExtraction)
        let visibleURL = await runURL(
            client: urlClient,
            imageBase64: fullImage,
            onEvent: onEvent
        )

        let workingImage: String
        if visibleURL?.url?.isEmpty == false {
            workingImage = (try? ImageEncoder.loadAndEncode(
                from: imageURL,
                longEdge: longEdge,
                jpegQuality: jpegQuality,
                cropTopFraction: 0.12
            )) ?? fullImage
        } else {
            workingImage = fullImage
        }

        onEvent(.startedRelevance)
        let relevance: RelevanceVerdict
        do {
            let prompt = try PromptStore.load("relevance")
            let (decoded, _) = try await activeClient.generateJSON(
                prompt: prompt,
                imageBase64: workingImage,
                as: RelevanceVerdict.self
            )
            relevance = decoded
        } catch {
            onEvent(.failed(error, stage: "relevance"))
            throw error
        }
        onEvent(.relevanceVerdict(relevance))

        guard relevance.isDesign else {
            let result = AgentResult(
                relevance: relevance,
                metadata: nil,
                palette: nil,
                visibleURL: visibleURL
            )
            onEvent(.finished(result))
            return result
        }

        let metadata: DesignMetadata?
        let palette: ColorPalette?
        if serial {
            metadata = granular
                ? await runMetadataGranular(
                    client: activeClient, imageBase64: workingImage,
                    serial: true, onEvent: onEvent)
                : await runMetadata(
                    client: activeClient, imageBase64: workingImage,
                    onEvent: onEvent)
            palette = await runPalette(
                client: activeClient, imageBase64: workingImage,
                onEvent: onEvent)
        } else {
            async let m: DesignMetadata? = granular
                ? runMetadataGranular(
                    client: activeClient, imageBase64: workingImage,
                    serial: false, onEvent: onEvent)
                : runMetadata(
                    client: activeClient, imageBase64: workingImage,
                    onEvent: onEvent)
            async let p: ColorPalette? = runPalette(
                client: activeClient, imageBase64: workingImage,
                onEvent: onEvent)
            (metadata, palette) = await (m, p)
        }

        let result = AgentResult(
            relevance: relevance,
            metadata: metadata,
            palette: palette,
            visibleURL: visibleURL
        )
        onEvent(.finished(result))
        return result
    }

    // ── Per-tool helpers ────────────────────────────────────────────────────

    private func runMetadata(
        client: OllamaClient,
        imageBase64: String,
        onEvent: @Sendable (Event) -> Void
    ) async -> DesignMetadata? {
        do {
            let prompt = try PromptStore.load("metadata")
            let (decoded, _) = try await client.generateJSON(
                prompt: prompt,
                imageBase64: imageBase64,
                as: DesignMetadata.self
            )
            // Sanitize tags here too — the non-granular path returns the
            // whole DesignMetadata in one shot, so the granular sanitizer
            // never sees these.
            var cleaned = decoded
            cleaned.tags = Self.sanitizeTags(decoded.tags)
            onEvent(.metadata(cleaned))
            return cleaned
        } catch {
            onEvent(.failed(error, stage: "metadata"))
            return nil
        }
    }

    private func runPalette(
        client: OllamaClient,
        imageBase64: String,
        onEvent: @Sendable (Event) -> Void
    ) async -> ColorPalette? {
        do {
            let prompt = try PromptStore.load("colors")
            let (decoded, _) = try await client.generateJSON(
                prompt: prompt,
                imageBase64: imageBase64,
                as: ColorPalette.self
            )
            onEvent(.palette(decoded))
            return decoded
        } catch {
            onEvent(.failed(error, stage: "palette"))
            return nil
        }
    }

    // ── Granular metadata: 5 parallel calls, one per field ─────────────────

    private struct StyleResult: Codable  { var style: String }
    private struct LayoutResult: Codable { var layout: String }
    private struct MoodResult: Codable   { var mood: String }
    private struct TagsResult: Codable   { var tags: [String] }

    /// Defensive sanitizer for tag tokens. Splits hyphenated/spaced/punct
    /// tokens into separate tags, lowercases, dedupes preserving order,
    /// and drops empties. Models reliably-ish honor the "no hyphens"
    /// instruction in the prompt; this is the safety net.
    private static func sanitizeTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for token in raw {
            let parts = token
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            for piece in parts {
                let s = String(piece)
                if s.isEmpty { continue }
                if seen.contains(s) { continue }
                seen.insert(s)
                out.append(s)
            }
        }
        return out
    }

    private func runMetadataGranular(
        client: OllamaClient,
        imageBase64: String,
        serial: Bool,
        onEvent: @escaping @Sendable (Event) -> Void
    ) async -> DesignMetadata? {
        let style: String?
        let typography: Typography?
        let layout: String?
        let mood: String?
        let tags: [String]?

        let typographyDecoder: @Sendable (Typography) -> (Typography, String) = { t in
            let snippet = [
                t.headings.isEmpty ? nil : "headings: \(t.headings.joined(separator: ", "))",
                t.bodies.isEmpty   ? nil : "body: \(t.bodies.joined(separator: ", "))",
                t.others.isEmpty   ? nil : "other: \(t.others.joined(separator: ", "))"
            ].compactMap { $0 }.joined(separator: " · ")
            return (t, snippet.isEmpty ? "no visible text" : snippet)
        }

        if serial {
            style = await fetchPerField(
                prompt: "metadata_style", display: "style",
                client: client, imageBase64: imageBase64, onEvent: onEvent,
                decoded: { (r: StyleResult) in (r.style, r.style) }
            )
            typography = await fetchPerField(
                prompt: "metadata_typography", display: "typography",
                client: client, imageBase64: imageBase64, onEvent: onEvent,
                decoded: typographyDecoder
            )
            layout = await fetchPerField(
                prompt: "metadata_layout", display: "layout",
                client: client, imageBase64: imageBase64, onEvent: onEvent,
                decoded: { (r: LayoutResult) in (r.layout, r.layout) }
            )
            mood = await fetchPerField(
                prompt: "metadata_mood", display: "mood",
                client: client, imageBase64: imageBase64, onEvent: onEvent,
                decoded: { (r: MoodResult) in (r.mood, r.mood) }
            )
            tags = await fetchPerField(
                prompt: "metadata_tags", display: "tags",
                client: client, imageBase64: imageBase64, onEvent: onEvent,
                decoded: { (r: TagsResult) in
                    let cleaned = Self.sanitizeTags(r.tags)
                    return (cleaned, cleaned.joined(separator: ", "))
                }
            )
        } else {
            async let s: String? = fetchPerField(
                prompt: "metadata_style", display: "style",
                client: client, imageBase64: imageBase64, onEvent: onEvent,
                decoded: { (r: StyleResult) in (r.style, r.style) }
            )
            async let t: Typography? = fetchPerField(
                prompt: "metadata_typography", display: "typography",
                client: client, imageBase64: imageBase64, onEvent: onEvent,
                decoded: typographyDecoder
            )
            async let l: String? = fetchPerField(
                prompt: "metadata_layout", display: "layout",
                client: client, imageBase64: imageBase64, onEvent: onEvent,
                decoded: { (r: LayoutResult) in (r.layout, r.layout) }
            )
            async let mo: String? = fetchPerField(
                prompt: "metadata_mood", display: "mood",
                client: client, imageBase64: imageBase64, onEvent: onEvent,
                decoded: { (r: MoodResult) in (r.mood, r.mood) }
            )
            async let tg: [String]? = fetchPerField(
                prompt: "metadata_tags", display: "tags",
                client: client, imageBase64: imageBase64, onEvent: onEvent,
                decoded: { (r: TagsResult) in
                    let cleaned = Self.sanitizeTags(r.tags)
                    return (cleaned, cleaned.joined(separator: ", "))
                }
            )
            (style, typography, layout, mood, tags) = await (s, t, l, mo, tg)
        }

        let merged = DesignMetadata(
            style: style ?? "other",
            typography: typography ?? Typography(),
            layout: layout ?? "other",
            mood: mood ?? "",
            tags: tags ?? []
        )
        onEvent(.metadata(merged))
        return merged
    }

    /// Generic helper for one per-field call. The `decoded` closure converts
    /// the raw decoded struct into (typed value, log snippet). Returns the
    /// typed value, or nil on failure.
    private func fetchPerField<R: Decodable, V>(
        prompt: String,
        display: String,
        client: OllamaClient,
        imageBase64: String,
        onEvent: @Sendable (Event) -> Void,
        decoded: (R) -> (V, String)
    ) async -> V? {
        onEvent(.fieldStarted(name: display))
        do {
            let template = try PromptStore.load(prompt)
            let (raw, _) = try await client.generateJSON(
                prompt: template,
                imageBase64: imageBase64,
                as: R.self
            )
            let (value, snippet) = decoded(raw)
            onEvent(.field(name: display, snippet: snippet))
            return value
        } catch {
            onEvent(.failed(error, stage: display))
            return nil
        }
    }

    private func runURL(
        client: OllamaClient,
        imageBase64: String,
        onEvent: @escaping @Sendable (Event) -> Void
    ) async -> VisibleURL? {
        // Cap the URL call at 90s. URL extraction is a nice-to-have — never
        // worth blocking the entire save behind a model that's swap-thrashing
        // (we saw a 182s hang on a cross-model contention case before
        // routing URL back to the active client). 90s gives a slow first
        // call plenty of room while still bounding worst-case lock-up.
        await withTaskGroup(of: VisibleURL?.self) { group in
            group.addTask {
                do {
                    let prompt = try PromptStore.load("url")
                    let (decoded, _) = try await client.generateJSON(
                        prompt: prompt,
                        imageBase64: imageBase64,
                        as: VisibleURL.self
                    )
                    onEvent(.visibleURL(decoded))
                    return decoded
                } catch {
                    onEvent(.failed(error, stage: "url"))
                    return nil
                }
            }
            group.addTask {
                // Critical: only log "timed out" if the sleep actually
                // ran to completion. When the URL task wins the race we
                // call group.cancelAll() — that cancels this sleep, which
                // throws CancellationError. Without the explicit isCancelled
                // check, the closure would continue past `try?` and emit a
                // misleading "timed out" log even on the happy path.
                do {
                    try await Task.sleep(nanoseconds: 90 * 1_000_000_000)
                } catch {
                    return nil
                }
                FileHandle.standardError.write(Data(
                    "[Agent] url extraction timed out after 90s — continuing without URL\n".utf8
                ))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
