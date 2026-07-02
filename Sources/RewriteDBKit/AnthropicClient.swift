import Foundation

public enum AnthropicError: LocalizedError, Equatable {
    case missingAPIKey
    case http(Int, String)
    case emptyResponse
    case network(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key set. Open Settings → Rewrite and paste your Anthropic key."
        case .http(let code, let message):
            return "Anthropic API error (\(code)): \(message)"
        case .emptyResponse:
            return "Claude returned an empty response."
        case .network(let message):
            return "Network error: \(message)"
        case .decoding(let message):
            return "Couldn't read the response: \(message)"
        }
    }

    /// Whether this failure means Claude is *unavailable* (vs. a request/content problem), so a
    /// configured local fallback should be tried. Network drops, a missing key, and auth / rate-limit
    /// / server errors are availability failures; a 400-class request error, an empty response, or a
    /// decode failure are not (retrying local would waste latency and mask the real problem).
    public var isAvailabilityFailure: Bool {
        switch self {
        case .network, .missingAPIKey:
            return true
        case .http(let code, _):
            return code == 401 || code == 403 || code == 429 || (500...599).contains(code)
        case .emptyResponse, .decoding:
            return false
        }
    }
}

/// Minimal Anthropic Messages API client over `URLSession` (there is no official
/// Anthropic Swift SDK). Only the two endpoints this app needs are implemented.
///
/// Response parsing lives in pure `static` helpers so it can be unit-tested without the network.
public struct AnthropicClient {
    public let apiKey: String
    static let apiVersion = "2023-06-01"
    private static let baseURL = "https://api.anthropic.com"

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    private func makeRequest(_ path: String, method: String = "GET", body: Data? = nil,
                             timeout: TimeInterval = 60) -> URLRequest {
        var request = URLRequest(url: URL(string: Self.baseURL + path)!)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body
        request.timeoutInterval = timeout
        return request
    }

    /// Live list of available models. Powers the always-current model picker.
    public func listModels() async throws -> [AnthropicModel] {
        let (data, response) = try await send(makeRequest("/v1/models?limit=1000"))
        try Self.validate(response, data)
        return try Self.parseModels(data)
    }

    /// Rewrite `text` using the given instruction (system prompt) and model. `timeout` can be
    /// shortened when a local fallback is available, so a hung request doesn't block for the full 60s.
    public func rewrite(text: String, systemPrompt: String, model: String,
                        maxTokens: Int = 8192, timeout: TimeInterval = 60) async throws -> String {
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [["role": "user", "content": text]]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await send(makeRequest("/v1/messages", method: "POST", body: body, timeout: timeout))
        try Self.validate(response, data)
        return try Self.parseRewriteText(data)
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw AnthropicError.network(error.localizedDescription)
        }
    }

    // MARK: - Pure parsing helpers (unit-tested)

    /// Decodes the `GET /v1/models` envelope into models.
    public static func parseModels(_ data: Data) throws -> [AnthropicModel] {
        do {
            return try JSONDecoder().decode(AnthropicModelsResponse.self, from: data).data
        } catch {
            throw AnthropicError.decoding(error.localizedDescription)
        }
    }

    /// Joins all `text` blocks from a Messages API response; throws `.emptyResponse` if none.
    public static func parseRewriteText(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? [[String: Any]] else {
            throw AnthropicError.decoding("unexpected response shape")
        }
        let result = content
            .compactMap { block -> String? in
                (block["type"] as? String) == "text" ? block["text"] as? String : nil
            }
            .joined()
        guard !result.isEmpty else { throw AnthropicError.emptyResponse }
        return result
    }

    /// Extracts Anthropic's `error.message` from an error body, if present.
    public static func extractErrorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else {
            return nil
        }
        return error["message"] as? String
    }

    /// Throws a clean, human-readable error for non-2xx responses (extracting
    /// Anthropic's `error.message` instead of dumping raw JSON like the original app did).
    private static func validate(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = extractErrorMessage(data)
                ?? String(data: data, encoding: .utf8)
                ?? "unknown error"
            throw AnthropicError.http(http.statusCode, message)
        }
    }
}
