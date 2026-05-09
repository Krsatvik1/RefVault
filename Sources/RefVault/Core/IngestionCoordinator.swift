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

    /// Fires once for every record that completes a pipeline run, whether
    /// it's a fresh ingest (`kind = .ingest`) or a regenerate
    /// (`kind = .regenerate`). The Double is wall-clock seconds the agent
    /// took. Wired in `RefVaultApp.onAppear` to drive the bottom-right
    /// notification — toast renders both kinds, with the kind controlling
    /// the dot color and verb ("saved" vs "refreshed").
    var onSaved: ((ScreenshotRecord, Double, ToastKind) -> Void)?

    /// Fires when a dropped image was already in the library (exact-byte
    /// or near-visual match). Carries the URL of the new file (so the
    /// toast can show it as the highlighted "NEW" thumbnail), every
    /// existing record it matched (for the thumb row), and the reason
    /// for the dedup. The toast offers a "Save it regardless" CTA which
    /// calls back into `enqueueBypassingDedup(_:)`.
    var onDuplicate: ((URL, [ScreenshotRecord], DuplicateReason) -> Void)?

    enum ToastKind { case ingest, regenerate }
    enum DuplicateReason { case exact, visual(hamming: Int) }

    private var processing = false
    /// Pending regenerate jobs, processed through the same pump as `pending`
    /// so we don't fan out parallel Ollama calls. Each entry is the record
    /// being re-evaluated and the URL of its stored image copy.
    private var pendingRegens: [(record: ScreenshotRecord, url: URL)] = []
    /// URLs the user explicitly opted to save through the duplicate
    /// toast's "Save it regardless" CTA. The dedup re-check inside
    /// process() skips any URL in this set; without that, the user's
    /// override would loop forever — process() would re-detect the
    /// dup and re-fire onDuplicate, the toast would re-show, and the
    /// agent run would never start.
    private var dedupBypassURLs: Set<URL> = []

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

    /// Add a URL to the ingestion queue. Skipped if:
    ///   1. exact same path is already a saved record (cheap, no I/O)
    ///   2. SHA-256 of bytes matches an existing record (catches re-imports
    ///      and Finder copies of the same file at a different path)
    ///   3. perceptual hash is within Hamming threshold of an existing
    ///      record (catches "same page, different tab open" / mid-animation)
    ///   4. already queued or currently in-flight
    /// Cases 2 + 3 fire the duplicate toast so the user gets feedback that
    /// their drop was acknowledged.
    func enqueue(_ url: URL) {
        guard !store.contains(sourcePath: url.path) else {
            FileHandle.standardError.write(Data(
                "[Queue] enqueue \(url.lastPathComponent) → SKIP (already in library by path)\n".utf8
            ))
            return
        }
        guard !pending.contains(url), inFlight != url else {
            FileHandle.standardError.write(Data(
                "[Queue] enqueue \(url.lastPathComponent) → SKIP (already queued / in-flight)\n".utf8
            ))
            return
        }

        // Hash-based dedup. Both calls are pure pixel/byte math, no Ollama,
        // no agent — so the cost here is bounded (~10ms SHA + ~30ms dHash
        // worst case) regardless of library size.
        if let sha = PerceptualHash.sha256(of: url),
           let dup = store.findExactDuplicate(sha: sha) {
            FileHandle.standardError.write(Data(
                "[Queue] enqueue \(url.lastPathComponent) → SKIP (exact dup of \(dup.id.uuidString.prefix(8)))\n".utf8
            ))
            onDuplicate?(url, [dup], .exact)
            return
        }
        if let phash = PerceptualHash.dHash(of: url) {
            let matches = store.findVisualDuplicates(phash: phash, threshold: 6)
            if let nearest = matches.first {
                FileHandle.standardError.write(Data(
                    "[Queue] enqueue \(url.lastPathComponent) → SKIP (visual dup of \(nearest.record.id.uuidString.prefix(8)), hamming=\(nearest.hamming), \(matches.count) total matches)\n".utf8
                ))
                onDuplicate?(url, matches.map(\.record), .visual(hamming: nearest.hamming))
                return
            }
        }

        pending.append(url)
        FileHandle.standardError.write(Data(
            "[Queue] enqueue \(url.lastPathComponent) → ingest (depth ingest=\(pending.count) regen=\(pendingRegens.count) inFlight=\(inFlight != nil))\n".utf8
        ))
        Task { await pump() }
    }

    /// Skip the dedup gates and force-enqueue the URL. Called when the
    /// user clicks "Save it regardless" on the duplicate toast.
    /// Also marks the URL in `dedupBypassURLs` so process()'s race
    /// re-check leaves it alone instead of looping back into onDuplicate.
    func enqueueBypassingDedup(_ url: URL) {
        guard !pending.contains(url), inFlight != url else {
            FileHandle.standardError.write(Data(
                "[Queue] bypass enqueue \(url.lastPathComponent) → SKIP (already queued / in-flight)\n".utf8
            ))
            return
        }
        dedupBypassURLs.insert(url)
        pending.append(url)
        FileHandle.standardError.write(Data(
            "[Queue] bypass enqueue \(url.lastPathComponent) → ingest (dedup gates skipped, depth=\(pending.count))\n".utf8
        ))
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

    /// Remove a queued regenerate from the queue. No-op if the record is
    /// already in-flight (Ollama call is mid-stream and can't be cancelled
    /// cleanly) or not present at all. Returns true if a queued job was
    /// actually removed.
    @discardableResult
    func cancelRegenerate(_ record: ScreenshotRecord) -> Bool {
        // Refuse if currently running. regenerateStartedAt[id] is set the
        // moment the pump pulls a regen out of pendingRegens.
        if regenerateStartedAt[record.id] != nil {
            FileHandle.standardError.write(Data(
                "[Queue] cancelRegenerate \(record.id.uuidString.prefix(8)) → SKIP (already in-flight)\n".utf8
            ))
            return false
        }
        let before = pendingRegens.count
        pendingRegens.removeAll(where: { $0.record.id == record.id })
        let removed = before - pendingRegens.count
        if removed > 0 {
            regeneratingIds.remove(record.id)
            FileHandle.standardError.write(Data(
                "[Queue] cancelRegenerate \(record.id.uuidString.prefix(8)) → removed from queue (depth regen=\(pendingRegens.count))\n".utf8
            ))
            return true
        }
        return false
    }

    /// Queue a record for regeneration. The agent will re-run the whole
    /// pipeline against the stored image and the result will replace the
    /// existing record's metadata via `store.update(record:with:)`.
    /// Idempotent — duplicate calls while one is already pending no-op.
    func regenerate(_ record: ScreenshotRecord) {
        guard let url = store.storedImageURL(for: record) else {
            FileHandle.standardError.write(Data(
                "[Queue] regenerate \(record.id.uuidString.prefix(8)) → SKIP (no stored image)\n".utf8
            ))
            return
        }
        guard !regeneratingIds.contains(record.id) else {
            FileHandle.standardError.write(Data(
                "[Queue] regenerate \(record.id.uuidString.prefix(8)) → SKIP (already pending)\n".utf8
            ))
            return
        }
        regeneratingIds.insert(record.id)
        pendingRegens.append((record, url))
        FileHandle.standardError.write(Data(
            "[Queue] regenerate \(record.id.uuidString.prefix(8)) → enqueued (depth ingest=\(pending.count) regen=\(pendingRegens.count) inFlight=\(inFlight != nil))\n".utf8
        ))
        Task { await pump() }
    }

    private func pump() async {
        guard !processing else {
            FileHandle.standardError.write(Data(
                "[Queue] pump skipped — already processing\n".utf8
            ))
            return
        }
        processing = true
        FileHandle.standardError.write(Data(
            "[Queue] pump START (ingest=\(pending.count) regen=\(pendingRegens.count))\n".utf8
        ))
        defer {
            processing = false
            FileHandle.standardError.write(Data(
                "[Queue] pump DONE — both queues drained\n".utf8
            ))
        }
        while !pending.isEmpty || !pendingRegens.isEmpty {
            // Drain new ingests first — they're typically user-triggered or
            // newly-arrived screenshots and the user is more likely waiting
            // on those. Regenerates are background polish.
            if !pending.isEmpty {
                let next = pending.removeFirst()
                inFlight = next
                inFlightStartedAt = Date()
                FileHandle.standardError.write(Data(
                    "[Queue] pick INGEST \(next.lastPathComponent) (remaining ingest=\(pending.count) regen=\(pendingRegens.count))\n".utf8
                ))
                await process(next)
                inFlightStartedAt = nil
                inFlight = nil
            } else if !pendingRegens.isEmpty {
                let job = pendingRegens.removeFirst()
                inFlight = job.url
                inFlightStartedAt = Date()
                regenerateStartedAt[job.record.id] = Date()
                FileHandle.standardError.write(Data(
                    "[Queue] pick REGEN \(job.record.id.uuidString.prefix(8)) (remaining ingest=\(pending.count) regen=\(pendingRegens.count))\n".utf8
                ))
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
        // Backfill hashes whenever we regenerate. Pre-dedup library entries
        // have nil hashes; this is the natural moment to fill them in.
        let sha = PerceptualHash.sha256(of: url)
        let phash = PerceptualHash.dHash(of: url)
        do {
            let result = try await agent.run(
                imageAt: url,
                granular: granularExtraction,
                serial: serialExecution,
                urlFirstFlow: urlFirstFlow
            )
            let elapsed = Date().timeIntervalSince(started)
            FileHandle.standardError.write(Data(
                "[Toast] agent returned (regen) isDesign=\(result.relevance.isDesign) conf=\(String(format: "%.2f", result.relevance.confidence)) elapsed=\(String(format: "%.1fs", elapsed))\n".utf8
            ))
            let updated = store.update(
                record: record,
                with: result,
                processingSeconds: elapsed,
                fileHash: sha,
                perceptualHash: phash
            )
            appendLog(LogLine(
                url: url,
                outcome: "regenerated · \(result.relevance.surface) · conf \(formatted(result.relevance.confidence)) · \(String(format: "%.1fs", elapsed))",
                saved: true
            ))
            // Regenerate always toasts — it's an explicit user-triggered
            // action, so they should see confirmation regardless of the
            // confidence threshold (which only gates fresh ingest).
            let toastRecord = updated ?? record
            let hasCb = onSaved != nil
            FileHandle.standardError.write(Data(
                "[Toast] regen done kind=regenerate id=\(toastRecord.id.uuidString.prefix(8)) elapsed=\(String(format: "%.1fs", elapsed)) onSaved=\(hasCb ? "wired" : "NIL")\n".utf8
            ))
            onSaved?(toastRecord, elapsed, .regenerate)
        } catch {
            FileHandle.standardError.write(Data(
                "[Toast] regen threw — \(error.localizedDescription)\n".utf8
            ))
            appendLog(LogLine(
                url: url,
                outcome: "regenerate error: \(error.localizedDescription)",
                saved: false
            ))
        }
    }

    private func process(_ url: URL) async {
        let started = Date()

        // Compute hashes up front. Cheap (~40ms total) and we'll need them
        // both for the race-safe re-check below AND to persist on the
        // saved record so future imports can dedup against this one.
        let sha = PerceptualHash.sha256(of: url)
        let phash = PerceptualHash.dHash(of: url)
        FileHandle.standardError.write(Data(
            "[Queue] hashes for \(url.lastPathComponent) sha=\(sha?.prefix(12) ?? "nil") phash=\(phash.map { String($0, radix: 16) } ?? "nil")\n".utf8
        ))

        // Race-safe re-check: between enqueue() and now, another item from
        // the queue may have been saved. Re-run the dedup against current
        // records before paying for the agent run — UNLESS the user
        // explicitly opted to override via "Save it regardless", in which
        // case we'd just loop back into onDuplicate forever.
        let bypassed = dedupBypassURLs.contains(url)
        if bypassed {
            dedupBypassURLs.remove(url)
            FileHandle.standardError.write(Data(
                "[Queue] process \(url.lastPathComponent) → bypass active, skipping dedup re-check\n".utf8
            ))
        } else {
            if let sha, let dup = store.findExactDuplicate(sha: sha) {
                FileHandle.standardError.write(Data(
                    "[Queue] process \(url.lastPathComponent) → SKIP (race-detected exact dup of \(dup.id.uuidString.prefix(8)))\n".utf8
                ))
                onDuplicate?(url, [dup], .exact)
                return
            }
            if let phash {
                let matches = store.findVisualDuplicates(phash: phash, threshold: 6)
                if let nearest = matches.first {
                    FileHandle.standardError.write(Data(
                        "[Queue] process \(url.lastPathComponent) → SKIP (race-detected visual dup of \(nearest.record.id.uuidString.prefix(8)), hamming=\(nearest.hamming))\n".utf8
                    ))
                    onDuplicate?(url, matches.map(\.record), .visual(hamming: nearest.hamming))
                    return
                }
            }
        }

        do {
            let result = try await agent.run(
                imageAt: url,
                granular: granularExtraction,
                serial: serialExecution,
                urlFirstFlow: urlFirstFlow
            )
            let elapsed = Date().timeIntervalSince(started)
            FileHandle.standardError.write(Data(
                "[Toast] agent returned isDesign=\(result.relevance.isDesign) conf=\(String(format: "%.2f", result.relevance.confidence)) surface=\(result.relevance.surface) elapsed=\(String(format: "%.1fs", elapsed))\n".utf8
            ))
            let keep = store.shouldKeep(result)
            FileHandle.standardError.write(Data(
                "[Toast] shouldKeep=\(keep) (threshold=\(String(format: "%.2f", store.confidenceThreshold)))\n".utf8
            ))
            if keep {
                if let saved = store.saveRecord(
                    from: result,
                    sourceURL: url,
                    processingSeconds: elapsed,
                    fileHash: sha,
                    perceptualHash: phash
                ) {
                    appendLog(LogLine(
                        url: url,
                        outcome: "saved · \(saved.relevance.surface) · \(saved.relevance.device) · conf \(formatted(saved.relevance.confidence))",
                        saved: true
                    ))
                    let hasCb = onSaved != nil
                    FileHandle.standardError.write(Data(
                        "[Toast] saveRecord ok kind=ingest id=\(saved.id.uuidString.prefix(8)) elapsed=\(String(format: "%.1fs", elapsed)) onSaved=\(hasCb ? "wired" : "NIL")\n".utf8
                    ))
                    onSaved?(saved, elapsed, .ingest)
                } else {
                    FileHandle.standardError.write(Data(
                        "[Toast] saveRecord returned nil — file copy failed\n".utf8
                    ))
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
                FileHandle.standardError.write(Data(
                    "[Toast] skipped → \(why) (no toast)\n".utf8
                ))
                appendLog(LogLine(url: url, outcome: "skipped: \(why)", saved: false))
            }
        } catch {
            FileHandle.standardError.write(Data(
                "[Toast] agent threw — \(error.localizedDescription)\n".utf8
            ))
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
