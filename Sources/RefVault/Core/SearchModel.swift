import Foundation

/// Holds the live search query and its parsed filter outside any single
/// SwiftUI view's @State. LibraryView re-renders whenever any
/// EnvironmentObject publishes — that was previously destroying focus and
/// resetting `query` mid-typing. With the query on a stable @StateObject
/// owned by the App, the TextField binding keeps working through every
/// re-render of the surrounding view tree.
@MainActor
final class SearchModel: ObservableObject {
    @Published var query: String = ""
    /// The query value that the grid actually filters by. Diverges from
    /// `query` while the user is mid-typing: only updates after the
    /// debounce window expires or when the user explicitly hits Enter.
    /// Without this the LibraryView grid was filtering on every keystroke,
    /// which made the grid feel jumpy.
    @Published private(set) var committedQuery: String = ""
    @Published private(set) var parsedFilter: SearchFilter? = nil
    @Published private(set) var parsedFilterFor: String = ""
    @Published private(set) var isParsing: Bool = false
    /// Wall-clock start of the current Gemma parse, set after the debounce
    /// sleep clears. Drives the live "+Ns" counter in the search field.
    /// Nil whenever no parse is in flight.
    @Published private(set) var parseStartedAt: Date? = nil
    @Published private(set) var parseError: String? = nil
    /// Tag chips the user has explicitly toggled on. Acts as an additional
    /// AND-constraint over whatever the AI parsed from the free-text query.
    @Published var selectedTags: Set<String> = []
    /// Drives result ordering in both the main library grid and the
    /// popover's horizontal rail.
    @Published var sortMode: SortMode = .recent

    enum SortMode: String, CaseIterable, Identifiable {
        case recent       // newest indexed first
        case oldest       // oldest indexed first
        case confidence   // highest confidence first
        case style        // alphabetical by style

        var id: String { rawValue }
        var label: String {
            switch self {
            case .recent: return "recent"
            case .oldest: return "oldest"
            case .confidence: return "confidence"
            case .style: return "style"
            }
        }
    }

    func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }

    /// Apply current sort mode to a record list. Pure function so callers
    /// can chain it after their own filtering.
    func sorted(_ records: [ScreenshotRecord]) -> [ScreenshotRecord] {
        switch sortMode {
        case .recent:
            return records.sorted { $0.indexedAt > $1.indexedAt }
        case .oldest:
            return records.sorted { $0.indexedAt < $1.indexedAt }
        case .confidence:
            return records.sorted { $0.relevance.confidence > $1.relevance.confidence }
        case .style:
            return records.sorted {
                ($0.metadata?.style ?? "") < ($1.metadata?.style ?? "")
            }
        }
    }

    private var parseTask: Task<Void, Never>?
    /// Set by the app once the agent is wired up. The model can't construct
    /// the parser itself because OllamaClient lives behind the agent.
    var parser: SearchParser?

    func clear() {
        query = ""
        committedQuery = ""
        parsedFilter = nil
        parsedFilterFor = ""
        isParsing = false
        parseStartedAt = nil
        parseError = nil
        parseTask?.cancel()
    }

    /// Called from the TextField's `.onChange`. Only reacts to the field
    /// being cleared — actual search/parse work is gated behind Enter
    /// (submit). Without this, every keystroke was either rescheduling a
    /// debounced parse or committing a substring filter; user wanted full
    /// manual control so the grid only updates on explicit confirmation.
    func schedule(_ newQuery: String) {
        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            parseTask?.cancel()
            parseError = nil
            parsedFilter = nil
            parsedFilterFor = ""
            committedQuery = ""
            selectedTags = []
            isParsing = false
        }
        // Non-empty: do nothing. The user has to press Enter (or click
        // the submit button) to commit the query.
    }

    /// Bypass the debounce — used when the user explicitly hits ⏎ in the
    /// search field. Cancels any pending debounced parse and fires now.
    func submit() {
        parseTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fresh slate — every new search wipes existing chips before the
        // parse runs, so AI-promoted chips can replace them cleanly.
        selectedTags = []
        // Commit immediately so the substring filter applies even before
        // Gemma returns (or if Gemma fails entirely).
        committedQuery = trimmed
        guard !trimmed.isEmpty, let parser = parser else { return }
        parseTask = launchParse(trimmed: trimmed, originalQuery: query, delay: 0, parser: parser)
    }

    private func launchParse(
        trimmed: String,
        originalQuery: String,
        delay: UInt64,
        parser: SearchParser
    ) -> Task<Void, Never> {
        Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            if Task.isCancelled { return }
            // Debounce passed — commit the query so the substring filter
            // kicks in immediately, in parallel with the (slower) Gemma
            // parse. If the parse succeeds, parsedFilter takes precedence
            // in LibraryView.currentResults; if it fails, the substring
            // filter is the fallback.
            self.committedQuery = trimmed
            // Fresh slate at commit — new search clears any existing
            // chips before Gemma's parsed values land. If parse succeeds
            // below, selectedTags is set to the new normalized set; if
            // parse fails, chips stay empty and substring search drives
            // the grid via committedQuery alone.
            self.selectedTags = []
            self.isParsing = true
            self.parseStartedAt = Date()
            defer {
                self.isParsing = false
                self.parseStartedAt = nil
            }
            do {
                let filter = try await parser.parse(query: trimmed)
                if Task.isCancelled || self.query != originalQuery { return }
                self.parsedFilter = filter
                self.parsedFilterFor = originalQuery
                // Promote every categorical value Gemma extracted into the
                // selectedTags set so it renders through the same chip row
                // the user's manual toggles use. Without this we had two
                // parallel chip styles ("clean ×" pills above, "mood: edgy"
                // labelled chips below) for the same conceptual thing.
                // freeText stays out — that's the substring fallback path
                // (driven by committedQuery), not a chip.
                var promoted = Set<String>()
                if let v = filter.styles       { promoted.formUnion(v) }
                if let v = filter.moods        { promoted.formUnion(v) }
                if let v = filter.tagsAll      { promoted.formUnion(v) }
                if let v = filter.tagsAny      { promoted.formUnion(v) }
                if let v = filter.colors       { promoted.formUnion(v) }
                if let v = filter.surfaces     { promoted.formUnion(v) }
                if let v = filter.devices      { promoted.formUnion(v) }
                if let v = filter.orientations { promoted.formUnion(v) }
                // Typography lands as slot-qualified tokens so a record
                // with serif headings + sans-serif body can be filtered
                // by either slot independently. Format mirrors how
                // chipHaystack stores typography for the same record.
                if let t = filter.typography {
                    if let v = t.headings {
                        promoted.formUnion(v.map { "heading: \($0.lowercased())" })
                    }
                    if let v = t.bodies {
                        promoted.formUnion(v.map { "body: \($0.lowercased())" })
                    }
                    if let v = t.others {
                        promoted.formUnion(v.map { "other: \($0.lowercased())" })
                    }
                }
                let normalized = promoted.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }.filter { !$0.isEmpty }
                self.selectedTags.formUnion(normalized)
            } catch {
                if !Task.isCancelled {
                    self.parseError = error.localizedDescription
                }
            }
        }
    }
}
