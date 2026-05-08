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
    @Published private(set) var queueDepth: Int = 0
    @Published private(set) var recentLog: [LogLine] = []

    let store: LibraryStore
    let agent: GemmaAgent

    private var queue: [URL] = []
    private var processing = false

    init(store: LibraryStore, agent: GemmaAgent) {
        self.store = store
        self.agent = agent
    }

    /// Add a URL to the ingestion queue. Skipped if already in the library
    /// or already queued.
    func enqueue(_ url: URL) {
        guard !store.contains(sourcePath: url.path) else { return }
        guard !queue.contains(url), inFlight != url else { return }
        queue.append(url)
        queueDepth = queue.count
        Task { await pump() }
    }

    private func pump() async {
        guard !processing else { return }
        processing = true
        defer { processing = false }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            queueDepth = queue.count
            inFlight = next
            await process(next)
            inFlight = nil
        }
    }

    private func process(_ url: URL) async {
        do {
            let result = try await agent.run(imageAt: url)
            if store.shouldKeep(result) {
                if let saved = store.saveRecord(from: result, sourceURL: url) {
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
