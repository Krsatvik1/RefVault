import Foundation

/// Minimal HTTP client for Ollama.
///
/// Uses /api/generate with `format: "json"` so Gemma is forced to return JSON.
/// Vision models accept a `images` field of base64-encoded image strings.
///
/// `baseURL` is `var` because the bundled-Ollama supervisor binds to a
/// dynamic port (so we don't collide with a user-installed Ollama on the
/// default 11434). The supervisor publishes its URL after `ollama serve`
/// is reachable, and we mutate every active client to point at it.
struct OllamaClient {
    var baseURL: URL
    var model: String
    let session: URLSession

    init(
        baseURL: URL = OllamaClient.defaultBaseURL,
        model: String = OllamaClient.defaultModel,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.model = model
        self.session = session
    }

    /// URL the client points at before the supervisor reports its real
    /// port. Matches the system-Ollama default so dev runs work even when
    /// the supervisor is disabled.
    static let defaultBaseURL = URL(string: "http://127.0.0.1:11434")!

    /// Default model used when no override is supplied. 26b MoE is the
    /// only model the app ships with — earlier we exposed e2b/e4b as
    /// faster variants but cross-model contention on a 24GB Mac (multiple
    /// models all wanting keep_alive=-1) made search calls swap-thrash and
    /// every ingest pay a model-switch penalty. Single model = predictable.
    static let defaultModel = "gemma4:26b"

    static let knownGemmaModels: [String] = ["gemma4:26b"]

    /// Model used for the URL extraction call. Defaults to nil so the URL
    /// call rides the same active client as everything else (no model
    /// switch, no second model load). Routing URL to a smaller model like
    /// e4b is a tempting micro-optimization but it forces Ollama to load a
    /// second model on top of the pinned 26b — on a 24GB machine this
    /// blows the memory budget and the URL call swap-thrashes for minutes
    /// before timing out, blocking the whole save. Keep them on one model.
    static let defaultURLModel: String? = nil

    /// Returns a copy of this client configured to talk to a different model.
    func withModel(_ name: String) -> OllamaClient {
        var copy = self
        copy.model = name
        return copy
    }

    /// Force-unload a model from VRAM by sending an empty-prompt /api/generate
    /// with `keep_alive: 0`. Used by the Debug "Force Cold" toggle so each
    /// run measures a true cold-load timing instead of riding warm weights
    /// from the previous run.
    func unload(model targetModel: String? = nil) async throws {
        struct UnloadRequest: Encodable {
            let model: String
            let keep_alive: Int
        }
        let body = UnloadRequest(
            model: targetModel ?? self.model,
            keep_alive: 0
        )
        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 60

        let started = Date()
        Self.log("→ unload \(body.model)")
        let (_, response) = try await session.data(for: req)
        Self.log("← unload \(body.model) \(Self.fmt(Date().timeIntervalSince(started)))")
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RefVaultError.ollamaUnreachable("unload failed")
        }
    }

    /// Pre-load a model into memory without running inference. Uses Ollama's
    /// "empty prompt" semantics on /api/generate: when no prompt is sent and
    /// `keep_alive` is -1, Ollama loads the weights and pins them. We call
    /// this on app launch so the user's first ingest doesn't pay the ~55s
    /// cold-load cost on the relevance call.
    func preload(model targetModel: String? = nil) async throws {
        struct PreloadRequest: Encodable {
            let model: String
            let keep_alive: Int
        }
        let body = PreloadRequest(
            model: targetModel ?? self.model,
            keep_alive: -1
        )
        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 120

        let started = Date()
        Self.log("→ preload \(body.model)")
        let (_, response) = try await session.data(for: req)
        Self.log("← preload \(body.model) \(Self.fmt(Date().timeIntervalSince(started)))")
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RefVaultError.ollamaUnreachable("preload failed")
        }
    }

    /// Health check — returns the list of locally pulled model tags.
    func listModels() async throws -> [String] {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        req.httpMethod = "GET"
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw RefVaultError.ollamaUnreachable("no HTTPURLResponse")
        }
        if http.statusCode != 200 {
            throw RefVaultError.ollamaHTTPError(
                http.statusCode,
                String(data: data, encoding: .utf8) ?? ""
            )
        }
        struct ListResponse: Decodable {
            struct ModelEntry: Decodable { let name: String }
            let models: [ModelEntry]
        }
        let decoded = try JSONDecoder().decode(ListResponse.self, from: data)
        return decoded.models.map(\.name)
    }

    /// Send a vision prompt with one base64-encoded image and parse the model's
    /// JSON output into the requested Decodable type.
    func generateJSON<T: Decodable>(
        prompt: String,
        imageBase64: String,
        as type: T.Type,
        temperature: Double = 0.2
    ) async throws -> (decoded: T, raw: String) {
        let raw = try await generateRaw(
            prompt: prompt,
            imageBase64: imageBase64,
            temperature: temperature
        )
        return try Self.decodeJSON(raw: raw, as: type)
    }

    /// Text-only variant — no image, used by helpers like the search-query
    /// parser. Same JSON-mode contract as the vision path.
    func generateTextJSON<T: Decodable>(
        prompt: String,
        as type: T.Type,
        temperature: Double = 0.0,
        numPredict: Int? = nil
    ) async throws -> (decoded: T, raw: String) {
        let raw = try await generateText(
            prompt: prompt,
            temperature: temperature,
            numPredict: numPredict
        )
        return try Self.decodeJSON(raw: raw, as: type)
    }

    private static func decodeJSON<T: Decodable>(
        raw: String,
        as type: T.Type
    ) throws -> (decoded: T, raw: String) {
        let cleaned = Self.extractJSONObject(from: raw)
        guard let data = cleaned.data(using: .utf8) else {
            throw RefVaultError.modelOutputNotJSON(raw)
        }
        do {
            let decoded = try JSONDecoder().decode(T.self, from: data)
            return (decoded, raw)
        } catch {
            throw RefVaultError.modelOutputNotJSON(raw)
        }
    }

    /// Returns the raw `response` string from Ollama.
    func generateRaw(
        prompt: String,
        imageBase64: String,
        temperature: Double = 0.2
    ) async throws -> String {
        struct GenerateRequest: Encodable {
            let model: String
            let prompt: String
            let images: [String]
            let stream: Bool
            let format: String
            let think: Bool
            let options: [String: Double]
            // -1 → never unload; "30m" → unload after 30 idle minutes.
            // We use -1 because the 26b's cold-load is ~55s and macOS will
            // keep paging it out under memory pressure even within Ollama's
            // default 5-min keep-alive — pinning forces it to stay touched.
            let keep_alive: Int
        }
        struct GenerateResponse: Decodable {
            let response: String
        }

        // Gemma 4 ships with "thinking" on by default — that produces a
        // {"thought": "..."} preamble instead of the JSON we asked for.
        // Disabling think + format=json gives us clean tool output.
        let body = GenerateRequest(
            model: model,
            prompt: prompt,
            images: [imageBase64],
            stream: false,
            format: "json",
            think: false,
            options: ["temperature": temperature],
            keep_alive: -1
        )

        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 180

        let promptHead = String(prompt.prefix(40)).replacingOccurrences(of: "\n", with: " ")
        let started = Date()
        Self.log("→ \(model) [\(promptHead)…] image=\(imageBase64.count)B")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            Self.log("✗ \(model) [\(promptHead)…] error after \(Self.fmt(Date().timeIntervalSince(started)))")
            throw RefVaultError.ollamaUnreachable(error.localizedDescription)
        }
        let elapsed = Date().timeIntervalSince(started)

        guard let http = response as? HTTPURLResponse else {
            throw RefVaultError.ollamaUnreachable("no HTTPURLResponse")
        }
        if http.statusCode != 200 {
            throw RefVaultError.ollamaHTTPError(
                http.statusCode,
                String(data: data, encoding: .utf8) ?? ""
            )
        }
        Self.log("← \(model) [\(promptHead)…] \(Self.fmt(elapsed))")
        let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        return decoded.response
    }

    private static func log(_ msg: String) {
        FileHandle.standardError.write(Data("[Ollama] \(msg)\n".utf8))
    }

    private static func fmt(_ s: TimeInterval) -> String {
        String(format: "%.2fs", s)
    }

    /// Text-only generate. Mirrors `generateRaw` but omits the `images`
    /// payload so the prompt is purely textual.
    ///
    /// `numPredict` caps output tokens; for short JSON responses (search-
    /// query parser) capping at ~256 makes the call return as soon as the
    /// model emits the closing brace instead of letting it ramble.
    func generateText(
        prompt: String,
        temperature: Double = 0.0,
        numPredict: Int? = nil
    ) async throws -> String {
        struct GenerateRequest: Encodable {
            let model: String
            let prompt: String
            let stream: Bool
            let format: String
            let think: Bool
            let options: [String: Double]
            let keep_alive: Int
        }
        struct GenerateResponse: Decodable {
            let response: String
        }

        var opts: [String: Double] = ["temperature": temperature]
        if let n = numPredict { opts["num_predict"] = Double(n) }
        let body = GenerateRequest(
            model: model,
            prompt: prompt,
            stream: false,
            format: "json",
            think: false,
            options: opts,
            keep_alive: -1
        )

        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 60

        let promptHead = String(prompt.prefix(40)).replacingOccurrences(of: "\n", with: " ")
        let started = Date()
        Self.log("→ \(model) [\(promptHead)…] text-only")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            Self.log("✗ \(model) [\(promptHead)…] error after \(Self.fmt(Date().timeIntervalSince(started)))")
            throw RefVaultError.ollamaUnreachable(error.localizedDescription)
        }
        Self.log("← \(model) [\(promptHead)…] \(Self.fmt(Date().timeIntervalSince(started)))")
        guard let http = response as? HTTPURLResponse else {
            throw RefVaultError.ollamaUnreachable("no HTTPURLResponse")
        }
        if http.statusCode != 200 {
            throw RefVaultError.ollamaHTTPError(
                http.statusCode,
                String(data: data, encoding: .utf8) ?? ""
            )
        }
        let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        return decoded.response
    }

    /// Best-effort extraction of the first balanced { ... } block from `raw`.
    /// Gemma occasionally wraps JSON in prose even with format:"json" set.
    static func extractJSONObject(from raw: String) -> String {
        guard let start = raw.firstIndex(of: "{") else { return raw }
        var depth = 0
        var inString = false
        var escape = false
        var i = start
        while i < raw.endIndex {
            let c = raw[i]
            if escape {
                escape = false
            } else if c == "\\" {
                escape = true
            } else if c == "\"" {
                inString.toggle()
            } else if !inString {
                if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(raw[start...i])
                    }
                }
            }
            i = raw.index(after: i)
        }
        return String(raw[start...])
    }
}
