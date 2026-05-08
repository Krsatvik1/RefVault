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
    let client: OllamaClient

    /// Streaming progress events the UI can subscribe to.
    enum Event {
        case startedRelevance
        case relevanceVerdict(RelevanceVerdict)
        case startedExtraction
        case metadata(DesignMetadata)
        case palette(ColorPalette)
        case visibleURL(VisibleURL)
        case finished(AgentResult)
        case failed(Error, stage: String)
    }

    /// Runs the agent over an image at `url` and returns the merged result.
    /// `onEvent` lets callers render progress as the pipeline streams.
    @discardableResult
    func run(
        imageAt url: URL,
        onEvent: @escaping @Sendable (Event) -> Void = { _ in }
    ) async throws -> AgentResult {
        let imageBase64 = try ImageEncoder.loadAndEncode(from: url)

        // ── Step 1: relevance gate ──────────────────────────────────────────
        onEvent(.startedRelevance)
        let relevance: RelevanceVerdict
        do {
            let prompt = try PromptStore.load("relevance")
            let (decoded, _) = try await client.generateJSON(
                prompt: prompt,
                imageBase64: imageBase64,
                as: RelevanceVerdict.self
            )
            relevance = decoded
        } catch {
            onEvent(.failed(error, stage: "relevance"))
            throw error
        }
        onEvent(.relevanceVerdict(relevance))

        // Early exit: not a design reference.
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

        // ── Step 2: parallel extraction ─────────────────────────────────────
        onEvent(.startedExtraction)

        async let metadataResult: DesignMetadata? = runMetadata(
            imageBase64: imageBase64,
            onEvent: onEvent
        )
        async let paletteResult: ColorPalette? = runPalette(
            imageBase64: imageBase64,
            onEvent: onEvent
        )
        async let urlResult: VisibleURL? = relevance.looksLikeBrowser
            ? runURL(imageBase64: imageBase64, onEvent: onEvent)
            : nil

        let (metadata, palette, visibleURL) = await (
            metadataResult, paletteResult, urlResult
        )

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
            onEvent(.metadata(decoded))
            return decoded
        } catch {
            onEvent(.failed(error, stage: "metadata"))
            return nil
        }
    }

    private func runPalette(
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

    private func runURL(
        imageBase64: String,
        onEvent: @Sendable (Event) -> Void
    ) async -> VisibleURL? {
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
}
