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
    @Published private(set) var parsedFilter: SearchFilter? = nil
    @Published private(set) var parsedFilterFor: String = ""
    @Published private(set) var isParsing: Bool = false
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
        parsedFilter = nil
        parsedFilterFor = ""
        isParsing = false
        parseError = nil
        parseTask?.cancel()
    }

    /// Debounce window before a typing pause counts as "user is done." Set
    /// long enough that mid-word pauses don't fire a Gemma call but short
    /// enough that hands-off-keyboard feels responsive. 1.5s is the
    /// Spotlight/Raycast default ballpark.
    private static let debounceNanos: UInt64 = 1_500_000_000

    /// Caller (the view's `.onChange`) invokes this after the binding writes.
    /// Done this way so the binding write doesn't fan out into a flurry of
    /// objectWillChange events from inside `didSet`, which was destroying
    /// the TextField's selection state mid-typing. The actual Gemma call is
    /// deferred by `debounceNanos` and cancelled if the user keeps typing.
    func schedule(_ newQuery: String) {
        parseTask?.cancel()
        parseError = nil
        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            parsedFilter = nil
            parsedFilterFor = ""
            isParsing = false
            return
        }
        guard trimmed.count >= 3, let parser = parser else {
            // Need at least 3 chars before bothering Gemma — single letters
            // don't carry enough signal and we'd just thrash the model.
            parsedFilter = nil
            parsedFilterFor = ""
            isParsing = false
            return
        }
        parseTask = launchParse(trimmed: trimmed, originalQuery: newQuery, delay: Self.debounceNanos, parser: parser)
    }

    /// Bypass the debounce — used when the user explicitly hits ⏎ in the
    /// search field. Cancels any pending debounced parse and fires now.
    func submit() {
        parseTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
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
            self.isParsing = true
            defer { self.isParsing = false }
            do {
                let filter = try await parser.parse(query: trimmed)
                if Task.isCancelled || self.query != originalQuery { return }
                self.parsedFilter = filter
                self.parsedFilterFor = originalQuery
            } catch {
                if !Task.isCancelled {
                    self.parseError = error.localizedDescription
                }
            }
        }
    }
}
