import Foundation

public enum ChatGPTError: LocalizedError, Equatable, Sendable {
    case notConnected
    case request(Int, String?, String, String?)
    case invalidResponse(String)
    case interrupted

    public var isUnauthorized: Bool {
        if case .request(401, _, _, _) = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Connect your ChatGPT plan in Settings → Rewrite."
        case .request(let status, let code, let message, let requestID):
            let guidance: String
            switch code {
            case "subscription_sharing_usage_limit_exceeded":
                guidance = "ChatGPT plan usage limit reached. Open Manage usage in Settings → Rewrite → ChatGPT plan."
            case "subscription_sharing_user_not_eligible":
                guidance = "This ChatGPT account or workspace isn't eligible for plan usage in Dictidy."
            default:
                guidance = "ChatGPT request failed (\(status)): \(message)"
            }
            return guidance + (code.map { " [\($0)]" } ?? "")
                + (requestID.map { " Request ID: \($0)" } ?? "")
        case .invalidResponse(let message):
            return "Couldn't complete the ChatGPT rewrite: \(message)"
        case .interrupted:
            return "ChatGPT did not finish the rewrite. Your original text has been kept. Try again."
        }
    }

    public static func response(_ data: Data, status: Int, requestID: String? = nil) -> Self {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let error = object["error"] as? [String: Any] ?? object
        return .request(status, error["code"] as? String,
                        error["message"] as? String ?? object["detail"] as? String
                            ?? String(data: data, encoding: .utf8) ?? "Unknown error", requestID)
    }
}

/// The public Responses endpoint with ChatGPT plan permission, never a ChatGPT private endpoint.
/// Its catalog and request contract differ from API-key access.
public struct ChatGPTClient: Sendable {
    public typealias StreamTransport = @Sendable (URLRequest) async throws
        -> (AsyncThrowingStream<String, Error>, URLResponse)

    private let accessToken: String
    private let connectionID: String
    private let transport: OpenAIClient.Transport

    public init(accessToken: String, connectionID: String,
                transport: @escaping OpenAIClient.Transport = { try await URLSession.shared.data(for: $0) }) {
        self.accessToken = accessToken
        self.connectionID = connectionID
        self.transport = transport
    }

    private func request(_ path: String) throws -> URLRequest {
        guard !accessToken.isEmpty, !connectionID.isEmpty else { throw ChatGPTError.notConnected }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/" + path)!)
        request.timeoutInterval = 120
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        return request
    }

    public func listModels() async throws -> [RewriteModel] {
        let (data, response) = try await transport(request("models"))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ChatGPTError.response(data, status: http.statusCode,
                                       requestID: http.value(forHTTPHeaderField: "x-request-id"))
        }
        return try Self.parseModels(data, connectionID: connectionID)
    }

    public static func parseModels(_ data: Data, connectionID: String) throws -> [RewriteModel] {
        struct Record: Decodable { let slug: String; let display_name: String?; let visibility: String? }
        struct Catalog: Decodable { let models: [Record] }
        do {
            return try JSONDecoder().decode(Catalog.self, from: data).models
                .filter { $0.visibility == "list" && !$0.slug.isEmpty }
                .map { RewriteModel(provider: .chatgpt, modelID: $0.slug, displayName: $0.display_name ?? $0.slug,
                                    connectionID: connectionID) }
        } catch { throw ChatGPTError.invalidResponse("Unexpected model catalog.") }
    }

    public func rewrite(text: String, systemPrompt: String, model: String,
                        streamTransport: StreamTransport) async throws -> String {
        var request = try request("responses")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "instructions": systemPrompt,
            "input": [["role": "user", "content": text]], "store": false, "stream": true
        ])
        // max_output_tokens and the other API-key tuning fields are unsupported on this route.
        let (lines, response) = try await streamTransport(request)
        let http = response as? HTTPURLResponse
        let requestID = http?.value(forHTTPHeaderField: "x-request-id")
        if let http, !(200..<300).contains(http.statusCode) {
            var body = ""
            for try await line in lines {
                body += line + "\n"
                if body.utf8.count > 65_536 { break }
            }
            throw ChatGPTError.response(Data(body.utf8), status: http.statusCode, requestID: requestID)
        }
        var stream = ChatGPTResponseStream(requestID: requestID)
        for try await line in lines {
            try Task.checkCancellation()
            if let text = try stream.receive(line) { return text }
        }
        try Task.checkCancellation()
        return try stream.finish()
    }
}

/// SSE framing, including comments and multiline data. Deltas never become pasteable output;
/// only a successful response.completed event can release the completed output items.
public struct ChatGPTResponseStream {
    private var pending: [String] = []
    private var completedItems: [Int: [String: Any]] = [:]
    private let requestID: String?

    public init(requestID: String? = nil) { self.requestID = requestID }

    public mutating func receive(_ line: String) throws -> String? {
        if line.isEmpty || line.hasPrefix("event:") { return try dispatch() }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            pending.append(value)
        }
        return nil
    }

    public mutating func finish() throws -> String {
        if let text = try dispatch() { return text }
        throw ChatGPTError.interrupted
    }

    private mutating func dispatch() throws -> String? {
        guard !pending.isEmpty else { return nil }
        let value = pending.joined(separator: "\n")
        pending.removeAll(keepingCapacity: true)
        if value == "[DONE]" { return nil }
        let data = Data(value.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            throw ChatGPTError.invalidResponse("Unexpected stream event.")
        }
        if type == "error" {
            throw ChatGPTError.response(data, status: 200, requestID: requestID)
        }
        if type == "response.output_item.done" {
            guard let index = object["output_index"] as? Int,
                  let item = object["item"] as? [String: Any] else {
                throw ChatGPTError.invalidResponse("Missing completed output item.")
            }
            completedItems[index] = item
            return nil
        }
        guard ["response.completed", "response.failed", "response.incomplete"].contains(type) else { return nil }
        guard var response = object["response"] as? [String: Any] else {
            throw ChatGPTError.invalidResponse("Missing terminal response.")
        }
        // Subscription streams can omit output from the terminal response. The done
        // items carry the full content; retain their order and still require completion.
        if type == "response.completed", (response["output"] as? [Any])?.isEmpty != false {
            response["output"] = completedItems.keys.sorted().compactMap { completedItems[$0] }
        }
        let body = try JSONSerialization.data(withJSONObject: response)
        if type == "response.failed" {
            throw ChatGPTError.response(body, status: 200, requestID: requestID)
        }
        guard type == "response.completed", response["status"] as? String == "completed" else {
            throw ChatGPTError.interrupted
        }
        do { return try OpenAIClient.parseRewriteText(body) }
        catch { throw ChatGPTError.invalidResponse(error.localizedDescription) }
    }
}
