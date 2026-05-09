import Foundation

/// Turns natural-language search queries into structured `SearchFilter`s by
/// asking Gemma. Pure utility — no observable state, just a one-shot async call.
///
/// The optional `vocabularyProvider` is read on every parse so the model gets
/// a fresh snapshot of the library's actual style/mood/tag values. Grounding
/// the prompt in the existing vocabulary stops Gemma from inventing close-
/// but-wrong synonyms ("magazine-like" when the library tags everything as
/// "editorial").
struct SearchParser {
    let client: OllamaClient
    let vocabularyProvider: (@MainActor () -> LibraryVocabulary?)?

    init(
        client: OllamaClient,
        vocabularyProvider: (@MainActor () -> LibraryVocabulary?)? = nil
    ) {
        self.client = client
        self.vocabularyProvider = vocabularyProvider
    }

    func parse(query: String) async throws -> SearchFilter {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchFilter() }
        let template = try PromptStore.load("search")
        let vocab = await currentVocabulary()
        let prompt = buildPrompt(template: template, vocabulary: vocab, query: trimmed)
        let (decoded, _) = try await client.generateTextJSON(
            prompt: prompt,
            as: SearchFilter.self
        )
        return decoded
    }

    @MainActor
    private func currentVocabulary() -> LibraryVocabulary? {
        vocabularyProvider?()
    }

    private func buildPrompt(
        template: String,
        vocabulary: LibraryVocabulary?,
        query: String
    ) -> String {
        var parts: [String] = [template]
        if let v = vocabulary, !v.isEmpty {
            parts.append("")
            parts.append("Library vocabulary (the values that ACTUALLY appear in")
            parts.append("the user's library — prefer these exact tokens when the")
            parts.append("query maps onto one. Only invent a new value if no")
            parts.append("vocabulary entry fits):")
            let sep = ", "
            if !v.styles.isEmpty {
                parts.append("- styles:    " + v.styles.joined(separator: sep))
            }
            if !v.moods.isEmpty {
                parts.append("- moods:     " + v.moods.joined(separator: sep))
            }
            if !v.layouts.isEmpty {
                parts.append("- layouts:   " + v.layouts.joined(separator: sep))
            }
            if !v.tags.isEmpty {
                parts.append("- tags:      " + v.tags.joined(separator: sep))
            }
            if !v.surfaces.isEmpty {
                parts.append("- surfaces:  " + v.surfaces.joined(separator: sep))
            }
            if !v.devices.isEmpty {
                parts.append("- devices:   " + v.devices.joined(separator: sep))
            }
        }
        parts.append("")
        parts.append(query)
        return parts.joined(separator: "\n")
    }
}
