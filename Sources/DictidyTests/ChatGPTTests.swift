import Foundation
import DictidyKit

private func streamTransport(_ body: String, status: Int = 200) -> ChatGPTClient.StreamTransport {
    { _ in
        let lines = AsyncThrowingStream<String, Error> { continuation in
            body.components(separatedBy: "\n").forEach { continuation.yield($0) }
            continuation.finish()
        }
        return (lines, HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/responses")!,
                                      statusCode: status, httpVersion: nil, headerFields: ["x-request-id": "request-test"])!)
    }
}

private func jwt(header: [String: Any] = ["alg": "RS256", "kid": "test-key"], claims: [String: Any]) throws -> String {
    try [header, claims].map { ChatGPTOAuth.base64URL(try JSONSerialization.data(withJSONObject: $0)) }
        .joined(separator: ".") + ".c2lnbmF0dXJl"
}

@MainActor
private func expectChatGPTError(_ name: String, _ predicate: (ChatGPTError) -> Bool,
                               _ body: () async throws -> Void) async {
    await checkAsync(name) {
        do { try await body(); return false }
        catch let error as ChatGPTError { return predicate(error) }
    }
}

@MainActor
func runChatGPTTests() async {
    print("ChatGPT connections and billing isolation")
    let api = RewriteModel(provider: .openai, modelID: "same-model", displayName: "GPT")
    let plan = RewriteModel(provider: .chatgpt, modelID: "same-model", displayName: "GPT", connectionID: "account-one")
    let other = RewriteModel(provider: .chatgpt, modelID: "same-model", displayName: "GPT", connectionID: "account-two")
    check("same model has different identities for API billing and each ChatGPT account",
          Set([api.id, plan.id, other.id]).count == 3 && plan.label == "ChatGPT plan · GPT")
    check("disconnecting a plan never selects a separately billed API model",
          RewriteModel.resolvedSelection(plan.id, models: [api, plan], configuredProviders: [.openai]) == plan.id)
    do {
        let old = data(#"{"provider":"openai","modelID":"same-model","displayName":"GPT"}"#)
        check("existing cached API models still decode without a connection ID",
              try JSONDecoder().decode(RewriteModel.self, from: old) == api)
        check("ChatGPT model persistence retains the account registration",
              try JSONDecoder().decode(RewriteModel.self, from: JSONEncoder().encode(plan)) == plan)
        let instruction = Instruction(name: "Subscription", systemPrompt: "Style", modelOverrideID: plan.id)
        let configuration = try RewriteConfiguration(instruction: instruction, defaultModelID: api.id,
            models: [api, plan], configuredProviders: [.openai, .chatgpt], baseSystemPrompt: "Base")
        check("instruction override captures the subscription account", configuration.model == plan)
        checkThrows("an account switch cannot satisfy a captured subscription override") {
            try configuration.validateAvailability(models: [api, other], configuredProviders: [.openai, .chatgpt])
        }
    } catch { check("ChatGPT model persistence and configuration", false) }

    print("ChatGPT OAuth public-client flow")
    let redirect = URL(string: "http://127.0.0.1:54321/auth/callback")!
    let first = ChatGPTOAuth.authorizationURL(clientID: nil, hostID: "urn:uuid:host", redirectURI: redirect,
                                             state: "random-state", nonce: "random-nonce", challenge: "pkce-challenge")
    let parameters = Dictionary(uniqueKeysWithValues: URLComponents(url: first, resolvingAgainstBaseURL: false)!
        .queryItems!.map { ($0.name, $0.value ?? "") })
    check("first login requests plan permission with PKCE and Dictidy's own registration",
          first.host == "auth.openai.com" && first.path == "/api/accounts/authorize"
          && parameters["client_id"] == "dynamic_agent_client" && parameters["agent_name_hint"] == "Dictidy"
          && parameters["redirect_uri"] == redirect.absoluteString && parameters["ext_agent_host_id"] == "urn:uuid:host"
          && parameters["state"] == "random-state" && parameters["nonce"] == "random-nonce"
          && parameters["code_challenge_method"] == "S256" && parameters["code_challenge"] == "pkce-challenge"
          && parameters["resource"] == ChatGPTOAuth.resource && parameters["scope"] == ChatGPTOAuth.scopes
          && parameters["client_secret"] == nil && parameters["prompt"] == nil)
    let returning = ChatGPTOAuth.authorizationURL(clientID: "issued-client", hostID: "urn:uuid:host", redirectURI: redirect,
                                                  state: "new-state", nonce: "nonce", challenge: "challenge",
                                                  idTokenHint: "retained-token", requestConsent: true)
    let returningParameters = Dictionary(uniqueKeysWithValues: URLComponents(url: returning, resolvingAgainstBaseURL: false)!
        .queryItems!.map { ($0.name, $0.value ?? "") })
    check("reconnection reuses the registration and requests consent only when chosen",
          returningParameters["client_id"] == "issued-client" && returningParameters["agent_name_hint"] == nil
          && returningParameters["id_token_hint"] == "retained-token" && returningParameters["prompt"] == "consent")
    check("form encoding preserves plus, equals, ampersand, spaces, and Unicode in credentials",
          String(data: ChatGPTOAuth.form(["code": "a+b=c& d/é", "client_id": "issued"]), encoding: .utf8)
              == "client_id=issued&code=a%2Bb%3Dc%26%20d%2F%C3%A9")
    check("base64url round trip handles padding and URL alphabet",
          ChatGPTOAuth.decodeBase64URL(ChatGPTOAuth.base64URL(Data([251, 255, 0, 1]))) == Data([251, 255, 0, 1])
          && ChatGPTOAuth.decodeBase64URL("not valid!") == nil)
    do {
        let issued = try ChatGPTOAuth.callback(URL(string: redirect.absoluteString + "?state=s&code=c&client_id=issued")!,
                                             state: "s", clientID: nil)
        check("new registration returns the issued client ID", issued.code == "c" && issued.clientID == "issued")
        let reused = try ChatGPTOAuth.callback(URL(string: redirect.absoluteString + "?state=s&code=c")!,
                                             state: "s", clientID: "issued")
        check("returning callback may omit the saved client ID", reused == issued)
    } catch { check("OAuth callback success", false) }
    let invalidCallbacks = [
        "/auth/callback", "/wrong?state=s&code=c&client_id=issued", "/auth/callback?state=wrong&code=c&client_id=issued",
        "/auth/callback?state=s&state=s&code=c&client_id=issued", "/auth/callback?state=s&error=access_denied",
        "/auth/callback?state=s&code=c", "/auth/callback?state=s&code=c&client_id=dynamic_agent_client",
        "/auth/callback?state=s&code=&client_id=issued", "/auth/callback?state=s&code=c&client_id="
    ]
    for path in invalidCallbacks {
        checkThrows("invalid or declined callback is rejected: \(path)") {
            _ = try ChatGPTOAuth.callback(URL(string: "http://127.0.0.1:54321" + path)!, state: "s", clientID: nil)
        }
    }
    checkThrows("reauthorization cannot replace a saved registration with another client") {
        _ = try ChatGPTOAuth.callback(URL(string: redirect.absoluteString + "?state=s&code=c&client_id=other")!,
                                     state: "s", clientID: "issued")
    }

    print("ChatGPT identity claim validation (signature verification is performed by the macOS service)")
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let claims: [String: Any] = ["iss": ChatGPTOAuth.issuer, "aud": "issued", "sub": "user-one",
                                "nonce": "nonce", "exp": now.timeIntervalSince1970 + 300, "email": "kat@example.test"]
    do {
        let parsed = try ChatGPTIDToken(jwt(claims: claims))
        let identity = try parsed.validateClaims(clientID: "issued", nonce: "nonce", expectedSubject: "user-one", now: now)
        check("validated claims retain the verified subject and account label",
              identity.subject == "user-one" && identity.email == "kat@example.test"
              && parsed.keyID == "test-key" && !parsed.signedData.isEmpty && !parsed.signature.isEmpty)
        var multiple = claims
        multiple["aud"] = ["issued", "another"]
        multiple["azp"] = "issued"
        multiple["nbf"] = now.timeIntervalSince1970
        multiple["email"] = nil
        check("multiple audiences require the right authorized party; email is optional",
              try ChatGPTIDToken(jwt(claims: multiple)).validateClaims(clientID: "issued", nonce: "nonce", now: now).email == nil)
    } catch { check("valid ID token claims", false) }
    for (key, value) in [("iss", "https://attacker.test" as Any), ("aud", "another"), ("nonce", "another"),
                         ("exp", now.timeIntervalSince1970 - 1), ("nbf", now.timeIntervalSince1970 + 120),
                         ("sub", ""), ("aud", ["issued", "another"])] {
        var invalid = claims
        invalid[key] = value
        checkThrows("identity rejects invalid \(key)") {
            _ = try ChatGPTIDToken(jwt(claims: invalid)).validateClaims(clientID: "issued", nonce: "nonce", now: now)
        }
    }
    checkThrows("reauthorization cannot substitute another subject") {
        _ = try ChatGPTIDToken(jwt(claims: claims)).validateClaims(clientID: "issued", nonce: "nonce",
                                                                 expectedSubject: "different-user", now: now)
    }
    checkThrows("identity without an audience is rejected") {
        var noAudience = claims
        noAudience["aud"] = nil
        _ = try ChatGPTIDToken(jwt(claims: noAudience)).validateClaims(clientID: "issued", nonce: "nonce", now: now)
    }
    for raw in ["invalid", "..", "a.b.c", "e30.e30.c2ln", "eyJhbGciOiJub25lIiwia2lkIjoiayJ9.e30.c2ln"] {
        checkThrows("malformed or unsigned identity token is rejected") { _ = try ChatGPTIDToken(raw) }
    }
    checkThrows("unsupported critical JWT headers are rejected") {
        _ = try ChatGPTIDToken(jwt(header: ["alg": "RS256", "kid": "key", "crit": ["extension"]], claims: claims))
    }

    print("ChatGPT catalog and streaming rewrite")
    let catalogBody = #"{"models":[{"slug":"same-model","display_name":"GPT","visibility":"list"},{"slug":"hidden","visibility":"hide"},{"slug":"second","visibility":"list"},{"slug":"","display_name":"Empty","visibility":"list"}]}"#
    await checkAsync("catalog request uses only the subscription token and account-specific schema") {
        let client = ChatGPTClient(accessToken: "subscription-token", connectionID: "account-one", transport: { request in
            guard request.url?.absoluteString == "https://api.openai.com/v1/models",
                  request.httpMethod == "GET", request.httpBody == nil,
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer subscription-token" else {
                throw ChatGPTError.invalidResponse("Wrong catalog request")
            }
            return (data(catalogBody), httpResponse(200))
        })
        let models = try await client.listModels()
        return models.map(\.modelID) == ["same-model", "second"] && models.first == plan && models.last?.displayName == "second"
    }
    checkThrows("API-key catalog cannot masquerade as a subscription catalog") {
        _ = try ChatGPTClient.parseModels(data(#"{"data":[{"id":"gpt"}]}"#), connectionID: "account")
    }
    await checkAsync("empty subscription catalog is valid") {
        try ChatGPTClient.parseModels(data(#"{"models":[]}"#), connectionID: "account").isEmpty
    }
    let completed = "data: {\"type\":\"response.completed\",\"response\":" + responseBody + "}\n\n"
    let client = ChatGPTClient(accessToken: "subscription-token", connectionID: "account-one")
    await checkAsync("subscription request sends supported fields and pastes only completed output") {
        let stream: ChatGPTClient.StreamTransport = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            guard request.url?.absoluteString == "https://api.openai.com/v1/responses", request.httpMethod == "POST",
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer subscription-token",
                  request.value(forHTTPHeaderField: "Accept") == "text/event-stream",
                  request.value(forHTTPHeaderField: "Content-Type") == "application/json",
                  Set(body.keys) == ["model", "instructions", "input", "store", "stream"],
                  body["stream"] as? Bool == true, body["store"] as? Bool == false,
                  body["model"] as? String == "same-model", body["instructions"] as? String == "BASE\n\nSTYLE",
                  let input = body["input"] as? [[String: String]], input == [["role": "user", "content": "Original"]] else {
                throw ChatGPTError.invalidResponse("Wrong subscription request")
            }
            return try await streamTransport("event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial\"}\n\n"
                + completed)(request)
        }
        return try await client.rewrite(text: "Original", systemPrompt: "BASE\n\nSTYLE", model: "same-model",
                                        streamTransport: stream) == "Vince,\n\nCould you check this?\n\nDanny"
    }
    await checkAsync("SSE supports comments, multiline data, and an unterminated final event") {
        let multiline = ": heartbeat\nid: 1\nretry: 100\nevent: response.completed\ndata: {\"type\":\"response.completed\",\ndata: \"response\":" + responseBody + "}"
        return try await client.rewrite(text: "x", systemPrompt: "s", model: "same-model",
                                       streamTransport: streamTransport(multiline)) == "Vince,\n\nCould you check this?\n\nDanny"
    }
    await checkAsync("next event marker dispatches data even if empty lines were omitted") {
        try await client.rewrite(text: "x", systemPrompt: "s", model: "same-model",
                                streamTransport: streamTransport(completed.trimmingCharacters(in: .newlines) + "\nevent: end"))
            == "Vince,\n\nCould you check this?\n\nDanny"
    }
    let itemDone = "data: " + #"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"She went to school yesterday."}]}}"# + "\n\n"
    let emptyCompletion = "data: " + #"{"type":"response.completed","response":{"status":"completed","output":[]}}"# + "\n\n"
    await checkAsync("subscription output items survive an empty terminal output array") {
        try await client.rewrite(text: "She go to school yesterday.", systemPrompt: "Correct grammar", model: "m",
                                streamTransport: streamTransport(itemDone + emptyCompletion)) == "She went to school yesterday."
    }
    await expectChatGPTError("completed items still require successful response completion", { $0 == .interrupted }) {
        _ = try await client.rewrite(text: "Original", systemPrompt: "s", model: "m",
                                    streamTransport: streamTransport(itemDone + "data: [DONE]\n\n"))
    }
    let badStreams: [(String, String, (ChatGPTError) -> Bool)] = [
        ("partial output cannot replace source", "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial\"}\n\n", { $0 == .interrupted }),
        ("DONE alone is not completion", "data: [DONE]\n\n", { $0 == .interrupted }),
        ("incomplete terminal response is rejected", "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\"}}\n\n", { $0 == .interrupted }),
        ("inconsistent completed event is rejected", "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"failed\"}}\n\n", { $0 == .interrupted }),
        ("missing terminal response is rejected", "data: {\"type\":\"response.completed\"}\n\n", { if case .invalidResponse = $0 { return true }; return false }),
        ("malformed stream JSON is rejected", "data: bad-json\n\n", { if case .invalidResponse = $0 { return true }; return false }),
        ("missing event type is rejected", "data: {}\n\n", { if case .invalidResponse = $0 { return true }; return false }),
        ("empty completed output is rejected", "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n", { if case .invalidResponse = $0 { return true }; return false }),
        ("midstream usage limit retains its code and request ID", "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\",\"message\":\"Limit\"}}}\n\n", {
            $0 == .request(200, "subscription_sharing_usage_limit_exceeded", "Limit", "request-test")
                && $0.localizedDescription.contains("Manage usage")
        }),
        ("top-level stream errors are rejected", "data: {\"type\":\"error\",\"code\":\"bad_request\",\"message\":\"Invalid\"}\n\n", {
            $0 == .request(200, "bad_request", "Invalid", "request-test")
        })
    ]
    for (name, body, predicate) in badStreams {
        await expectChatGPTError(name, predicate) {
            _ = try await client.rewrite(text: "x", systemPrompt: "s", model: "same-model", streamTransport: streamTransport(body))
        }
    }
    for (status, body) in [(401, #"{"detail":"Expired"}"#), (403, #"{"error":{"code":"subscription_sharing_user_not_eligible","message":"Not eligible"}}"#), (503, "Unavailable")] {
        await expectChatGPTError("HTTP \(status) preserves subscription diagnostics", {
            if case .request(let code, _, _, let id) = $0 { return code == status && id == "request-test" }
            return false
        }) {
            _ = try await client.rewrite(text: "x", systemPrompt: "s", model: "m", streamTransport: streamTransport(body, status: status))
        }
    }
    await expectChatGPTError("oversized HTTP error bodies are bounded", {
        if case .request(500, _, let message, _) = $0 { return message.hasPrefix("Unavailable") }
        return false
    }) {
        _ = try await client.rewrite(text: "x", systemPrompt: "s", model: "m",
            streamTransport: streamTransport("Unavailable " + String(repeating: "x", count: 65_536), status: 500))
    }
    await expectChatGPTError("catalog HTTP failures retain structured errors", { $0.isUnauthorized }) {
        _ = try await ChatGPTClient(accessToken: "token", connectionID: "account", transport: stubTransport(401, #"{"detail":"Expired"}"#)).listModels()
    }
    for (accessToken, accountID) in [("", "account"), ("token", "")] {
        await expectChatGPTError("missing connection never sends a request", { $0 == .notConnected }) {
            _ = try await ChatGPTClient(accessToken: accessToken, connectionID: accountID,
                                       transport: { _ in fatalError("Must not send") }).listModels()
        }
    }
    await checkAsync("stream transport errors propagate without producing a rewrite") {
        do {
            _ = try await client.rewrite(text: "x", systemPrompt: "s", model: "m", streamTransport: { _ in
                (AsyncThrowingStream { $0.finish(throwing: URLError(.networkConnectionLost)) }, httpResponse(200))
            })
            return false
        } catch let error as URLError { return error.code == .networkConnectionLost }
    }
    await checkAsync("cancelled streams cannot return completed text") {
        let task = Task {
            try await client.rewrite(text: "x", systemPrompt: "s", model: "m", streamTransport: streamTransport(completed))
        }
        task.cancel()
        do { _ = try await task.value; return false }
        catch is CancellationError { return true }
    }
    let errors: [ChatGPTError] = [.notConnected, .interrupted, .invalidResponse("shape"),
        .request(503, nil, "Unavailable", "id"),
        .request(403, "subscription_sharing_user_not_eligible", "No", nil)]
    check("connection errors explain recovery", errors.allSatisfy { !$0.localizedDescription.isEmpty }
          && !ChatGPTError.notConnected.isUnauthorized
          && ChatGPTError.response(Data([0xff]), status: 500) == .request(500, nil, "Unknown error", nil))
}
