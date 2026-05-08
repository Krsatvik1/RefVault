import Foundation

/// Minimal HTTP client for Ollama running on localhost:11434.
///
/// Uses /api/generate with `format: "json"` so Gemma is forced to return JSON.
/// Vision models accept a `images` field of base64-encoded image strings.
struct OllamaClient {
    let baseURL: URL
    var model: String
    let session: URLSession

    init(
        baseURL: URL = URL(string: "http://localhost:11434")!,
        model: String = OllamaClient.defaultModel,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.model = model
        self.session = session
    }

    /// Default model used when no override is supplied. The lighter `e4b`
    /// variant runs comfortably on a 24GB-RAM Mac. Swap to `gemma4:26b` for
    /// higher-quality but slower runs.
    static let defaultModel = "gemma4:e4b"

    /// All gemma4 tags the UI knows about. Surfaced in the debug picker so
    /// the user can A/B between sizes.
    static let knownGemmaModels: [String] = [
        "gemma4:e4b",
        "gemma4:e2b",
        "gemma4:26b"
    ]

    /// Returns a copy of this client configured to talk to a different model.
    func withModel(_ name: String) -> OllamaClient {
        var copy = self
        copy.model = name
        return copy
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
            options: ["temperature": temperature]
        )

        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 180

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw RefVaultError.ollamaUnreachable(error.localizedDescription)
        }

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
