import Foundation

/// Coordinates the watcher → agent → library pipeline.
///
/// Serializes ingestion (one image at a time) so we don't fan out N parallel
/// Gemma jobs and overwhelm Ollama. The agent itself already runs its three
/// extractors in parallel for one image, which is the sweet spot.
@MainActor
final class IngestionCoordinator: ObservableObject {
    struct LogLine: Identifiable, Equatable {
        let id = UUID()
        let timestamp = Date()
        let url: URL
        let outcome: String
        let saved: Bool
    }

    @Published private(set) var inFlight: URL?
    @Published private(set) var pending: [URL] = []
    @Published private(set) var recentLog: [LogLine] = []
    /// IDs of records currently waiting to regenerate (queued or in flight).
    /// LibraryView reads this to animate the corresponding cards.
    @Published private(set) var regeneratingIds: Set<UUID> = []
    /// Wall-clock timestamp when whatever is in `inFlight` started running.
    /// Used to render elapsed time next to the loader. Nil when idle.
    @Published private(set) var inFlightStartedAt: Date?
    /// When each regenerate-record-id transitioned from "queued" to "running."
    /// Used by `LibraryCard` to show "+12.3s" next to its regenerating pill.
    @Published private(set) var regenerateStartedAt: [UUID: Date] = [:]
    /// Live model name used for the auto-ingest path. Mutated from Settings.
    @Published var primaryModel: String {
        didSet {
            UserDefaults.standard.set(primaryModel, forKey: Self.primaryModelKey)
            agent.client.model = primaryModel
        }
    }
    /// Whether the auto-ingest path (and DetailView's Regenerate button)
    /// runs the metadata extraction in granular mode (5 per-field calls).
    @Published var granularExtraction: Bool {
        didSet { UserDefaults.standard.set(granularExtraction, forKey: Self.granularKey) }
    }
    /// Whether Ollama calls run one at a time. Recommended on for small models.
    @Published var serialExecution: Bool {
        didSet { UserDefaults.standard.set(serialExecution, forKey: Self.serialKey) }
    }
    /// When ON: run URL extraction first; if a URL comes back, crop the
    /// top of the image and run relevance/metadata/palette on the cropped
    /// version (avoids browser chrome polluting the palette + typography).
    /// When OFF (default): original parallel flow — relevance first, then
    /// metadata + palette + URL fan out together with no cropping.
    @Published var urlFirstFlow: Bool {
        didSet { UserDefaults.standard.set(urlFirstFlow, forKey: Self.urlFirstKey) }
    }

    /// Pending ingest URLs only — preserved for callers that want to render
    /// just the auto-ingest queue.
    var queueDepth: Int { pending.count }

    /// All work that's not yet complete: queued ingests, queued regenerates,
    /// and the currently-processing item. Used by the menu-bar indexing pill
    /// so a regenerate flood shows the right count.
    var totalInProgress: Int {
        pending.count + pendingRegens.count + (inFlight != nil ? 1 : 0)
    }

    let store: LibraryStore
    var agent: GemmaAgent

    private var processing = false
    /// Pending regenerate jobs, processed through the same pump as `pending`
    /// so we don't fan out parallel Ollama calls. Each entry is the record
    /// being re-evaluated and the URL of its stored image copy.
    private var pendingRegens: [(record: ScreenshotRecord, url: URL)] = []

    private static let primaryModelKey = "refvault.primaryModel"
    private static let granularKey = "refvault.granularExtraction"
    private static let serialKey = "refvault.serialExecution"
    private static let urlFirstKey = "refvault.urlFirstFlow"

    init(store: LibraryStore, agent: GemmaAgent) {
        self.store = store
        self.agent = agent
        let stored = UserDefaults.standard.string(forKey: Self.primaryModelKey)
            ?? agent.client.model
        self.primaryModel = stored
        // UserDefaults.bool returns false for missing keys; check via object()
        // to honor first-launch defaults. Defaults: primary=gemma4:26b
        // (heavyweight quality), granular ON (per-field calls), serial OFF
        // (parallel — let Ollama overlap calls).
        let g = UserDefaults.standard.object(forKey: Self.granularKey) as? Bool
        self.granularExtraction = g ?? true
        let s = UserDefaults.standard.object(forKey: Self.serialKey) as? Bool
        self.serialExecution = s ?? false
        let u = UserDefaults.standard.object(forKey: Self.urlFirstKey) as? Bool
        self.urlFirstFlow = u ?? false
        self.agent.client.model = stored
    }

    /// Add a URL to the ingestion queue. Skipped if already in the library
    /// or already queued or currently in-flight.
    func enqueue(_ url: URL) {
        guard !store.contains(sourcePath: url.path) else { return }
        guard !pending.contains(url), inFlight != url else { return }
        pending.append(url)
        Task { await pump() }
    }

    /// Remove a queued URL that has not yet started processing. The
    /// in-flight item cannot be cancelled mid-run (Ollama call is in-flight).
    func cancel(_ url: URL) {
        pending.removeAll(where: { $0 == url })
    }

    /// Drop everything that has not started processing yet.
    func clearPending() {
        pending.removeAll()
    }

    /// Queue a record for regeneration. The agent will re-run the whole
    /// pipeline against the stored image and the result will replace the
    /// existing record's metadata via `store.update(record:with:)`.
    /// Idempotent — duplicate calls while one is already pending no-op.
    func regenerate(_ record: ScreenshotRecord) {
        guard let url = store.storedImageURL(for: record) else { return }
        guard !regeneratingIds.contains(record.id) else { return }
        regeneratingIds.insert(record.id)
        pendingRegens.append((record, url))
        Task { await pump() }
    }

    private func pump() async {
        guard !processing else { return }
        processing = true
        defer { processing = false }
        while !pending.isEmpty || !pendingRegens.isEmpty {
            // Drain new ingests first — they're typically user-triggered or
            // newly-arrived screenshots and the user is more likely waiting
            // on those. Regenerates are background polish.
            if !pending.isEmpty {
                let next = pending.removeFirst()
                inFlight = next
                inFlightStartedAt = Date()
                await process(next)
                inFlightStartedAt = nil
                inFlight = nil
            } else if !pendingRegens.isEmpty {
                let job = pendingRegens.removeFirst()
                inFlight = job.url
                inFlightStartedAt = Date()
                regenerateStartedAt[job.record.id] = Date()
                await processRegen(record: job.record, url: job.url)
                regenerateStartedAt.removeValue(forKey: job.record.id)
                inFlightStartedAt = nil
                inFlight = nil
                regeneratingIds.remove(job.record.id)
            }
        }
    }

    private func processRegen(record: ScreenshotRecord, url: URL) async {
        let started = Date()
        do {
            let result = try await agent.run(
                imageAt: url,
                granular: granularExtraction,
                serial: serialExecution,
                urlFirstFlow: urlFirstFlow
            )
            let elapsed = Date().timeIntervalSince(started)
            _ = store.update(record: record, with: result, processingSeconds: elapsed)
            appendLog(LogLine(
                url: url,
                outcome: "regenerated · \(result.relevance.surface) · conf \(formatted(result.relevance.confidence)) · \(String(format: "%.1fs", elapsed))",
                saved: true
            ))
        } catch {
            appendLog(LogLine(
                url: url,
                outcome: "regenerate error: \(error.localizedDescription)",
                saved: false
            ))
        }
    }

    private func process(_ url: URL) async {
        let started = Date()
        do {
            let result = try await agent.run(
                imageAt: url,
                granular: granularExtraction,
                serial: serialExecution,
                urlFirstFlow: urlFirstFlow
            )
            let elapsed = Date().timeIntervalSince(started)
            if store.shouldKeep(result) {
                if let saved = store.saveRecord(
                    from: result,
                    sourceURL: url,
                    processingSeconds: elapsed
                ) {
                    appendLog(LogLine(
                        url: url,
                        outcome: "saved · \(saved.relevance.surface) · \(saved.relevance.device) · conf \(formatted(saved.relevance.confidence))",
                        saved: true
                    ))
                } else {
                    appendLog(LogLine(
                        url: url,
                        outcome: "save failed (file copy error)",
                        saved: false
                    ))
                }
            } else {
                let why = result.relevance.isDesign
                    ? "below threshold (\(formatted(result.relevance.confidence)))"
                    : "not design — \(result.relevance.reason)"
                appendLog(LogLine(url: url, outcome: "skipped: \(why)", saved: false))
            }
        } catch {
            appendLog(LogLine(
                url: url,
                outcome: "error: \(error.localizedDescription)",
                saved: false
            ))
        }
    }

    private func appendLog(_ line: LogLine) {
        recentLog.insert(line, at: 0)
        if recentLog.count > 80 { recentLog = Array(recentLog.prefix(80)) }
    }

    private func formatted(_ x: Double) -> String {
        String(format: "%.2f", x)
    }
}
