import Foundation

/// Streams Ollama's `/api/pull` NDJSON response so the first-run UI can
/// render a real progress bar instead of a spinner that lies for 8
/// minutes while a 15GB blob downloads.
///
/// Ollama emits one JSON object per line. The interesting shape:
/// ```
///   {"status":"pulling 89cd2bafa75d","total":2592832,"completed":2592832}
///   {"status":"pulling 1abc...",       "total":17171140736,"completed":12012345}
///   {"status":"verifying sha256 digest"}
///   {"status":"writing manifest"}
///   {"status":"success"}
/// ```
/// Multiple "pulling <digest>" lines fire as the model is split across
/// layers; we sum the layer totals for the headline progress.
struct ModelDownloader {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Snapshot reported up to the UI. Aggregated across layers so the
    /// progress bar only ever moves forward.
    struct Progress: Equatable {
        /// "pulling manifest" / "pulling <digest>" / "verifying" / "writing manifest" / "success"
        var status: String
        /// Bytes pulled so far across every digest we've seen this run.
        var completedBytes: Int64
        /// Sum of every layer's announced total. Grows as new digests
        /// appear in the stream.
        var totalBytes: Int64
        /// Convenience for the progress bar. Returns nil while we don't
        /// yet have a total.
        var fraction: Double? {
            guard totalBytes > 0 else { return nil }
            return min(1.0, Double(completedBytes) / Double(totalBytes))
        }

        static let starting = Progress(
            status: "starting…",
            completedBytes: 0,
            totalBytes: 0
        )
    }

    /// Stream a model pull. The closure fires for every progress event
    /// the daemon emits. Throws on HTTP error or if the daemon reports
    /// `error` inline; returns normally on `status: "success"`.
    func pull(
        model: String,
        onProgress: @MainActor @escaping (Progress) -> Void
    ) async throws {
        struct PullRequest: Encodable {
            let model: String
            let stream: Bool
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(PullRequest(model: model, stream: true))
        // No timeout — a 26B pull on a slow connection legitimately
        // takes 30+ minutes. URLSession defaults to 60s which would
        // trip on every single pull.
        req.timeoutInterval = .infinity

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw RefVaultError.ollamaUnreachable("pull: no HTTPURLResponse")
        }
        if http.statusCode != 200 {
            throw RefVaultError.ollamaHTTPError(http.statusCode, "pull HTTP error")
        }

        // Per-digest accounting. Ollama re-emits the same digest's progress
        // many times; we track the most recent `completed` per digest so
        // the global counter doesn't double-count.
        var perLayerCompleted: [String: Int64] = [:]
        var perLayerTotal: [String: Int64] = [:]
        var lastEmitted = Progress.starting

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8) else { continue }
            let event = try? JSONDecoder().decode(PullEvent.self, from: data)
            guard let event else { continue }

            if let err = event.error, !err.isEmpty {
                throw RefVaultError.ollamaUnreachable("pull error: \(err)")
            }

            // Only digest-bearing events update byte counters. Status-only
            // events ("pulling manifest", "verifying…") just update the
            // human-readable label.
            if let digest = event.digest {
                if let total = event.total {
                    perLayerTotal[digest] = total
                }
                if let completed = event.completed {
                    perLayerCompleted[digest] = completed
                }
            }

            let totalBytes = perLayerTotal.values.reduce(0, +)
            let completedBytes = perLayerCompleted.values.reduce(0, +)
            let progress = Progress(
                status: event.status ?? lastEmitted.status,
                completedBytes: completedBytes,
                totalBytes: totalBytes
            )
            // Suppress no-op duplicates so the UI doesn't redraw on every
            // identical event (Ollama re-emits the same line every ~250ms
            // while a layer is mid-download).
            if progress != lastEmitted {
                lastEmitted = progress
                await onProgress(progress)
            }
            if event.status == "success" { return }
        }
    }

    private struct PullEvent: Decodable {
        let status: String?
        let digest: String?
        let total: Int64?
        let completed: Int64?
        let error: String?
    }
}
