import Foundation
import Security
import DictidyKit

/// Real loopback networking and Security.framework signatures, using only ephemeral test keys.
@main
struct ChatGPTPlatformTests {
    private final class MemoryVault {
        var data: Data?
        var store: ChatGPTCredentialStore {
            ChatGPTCredentialStore(load: { self.data }, save: { self.data = $0 },
                                   delete: { self.data = nil }, exists: { self.data != nil })
        }
        var contents: [String: [String: Any]] {
            (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: [String: Any]]) ?? [:]
        }
    }

    private actor TokenEndpoint {
        let status: Int
        let body: Data
        let pause: Bool
        var requests = 0
        var revocations: [String] = []
        var started: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<Void, Never>?

        init(pause: Bool = false, status: Int = 200, body: String? = nil) {
            self.pause = pause
            self.status = status
            self.body = Data((body ?? #"{"access_token":"fresh-access","refresh_token":"fresh-refresh","token_type":"Bearer","expires_in":3600,"scope":"openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"}"#).utf8)
        }

        func handle(_ request: URLRequest) async -> (Data, URLResponse) {
            if request.url?.path.hasSuffix("/revoke") == true {
                revocations.append(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            requests += 1
            started?.resume(); started = nil
            if pause { await withCheckedContinuation { release = $0 } }
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        func waitForRequest() async {
            if requests == 0 { await withCheckedContinuation { started = $0 } }
        }
        func resume() { release?.resume(); release = nil }
    }

    static func check(_ label: String, _ value: Bool) {
        precondition(value, label)
        print("  ✓ \(label)")
    }

    static func expectFailure(_ label: String, _ operation: () async throws -> Void) async {
        do { try await operation(); preconditionFailure(label) }
        catch { print("  ✓ \(label)") }
    }

    @MainActor
    static func main() async throws {
        print("ChatGPT native callback listener")
        let server = ChatGPTCallbackServer(state: "test-state", clientID: nil)
        let url = try await server.start()
        check("callback binds specifically to an available loopback port", url.host == "127.0.0.1" && url.port != nil)
        let wrong = URL(string: url.absoluteString + "?state=wrong&code=test&client_id=test-client")!
        let (_, rejected) = try await ChatGPTHTTP.session.data(from: wrong)
        check("unrelated callbacks do not consume sign-in", (rejected as? HTTPURLResponse)?.statusCode == 400)
        let correct = URL(string: url.absoluteString + "?state=test-state&code=test-code&client_id=test-client")!
        let (_, accepted) = try await ChatGPTHTTP.session.data(from: correct)
        let authorization = try await server.waitForCallback()
        check("real browser-style callback completes the pending sign-in",
              (accepted as? HTTPURLResponse)?.statusCode == 200 && authorization.clientID == "test-client"
              && authorization.code == "test-code")
        let cancelled = ChatGPTCallbackServer(state: "s", clientID: "client")
        _ = try await cancelled.start()
        cancelled.cancel()
        await expectFailure("cancel closes the listener and releases the pending callback") {
            _ = try await cancelled.waitForCallback()
        }

        print("ChatGPT native identity signature verification")
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
        let publicKey = SecKeyCopyPublicKey(privateKey)!
        let publicDER = SecKeyCopyExternalRepresentation(publicKey, nil)! as Data
        let parts = rsaComponents(publicDER)
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [[
            "kty": "RSA", "kid": "ephemeral-test-key", "use": "sig", "alg": "RS256",
            "n": ChatGPTOAuth.base64URL(parts.0), "e": ChatGPTOAuth.base64URL(parts.1)
        ]]])
        let discovery = Data(#"{"issuer":"https://auth.openai.com","jwks_uri":"https://auth.openai.com/.well-known/jwks.json"}"#.utf8)
        let transport: OpenAIClient.Transport = { request in
            let body = request.url?.path == "/.well-known/openid-configuration" ? discovery : jwks
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let claims: [String: Any] = ["iss": ChatGPTOAuth.issuer, "aud": "test-client", "nonce": "nonce",
                                    "sub": "test-subject", "email": "kat@example.test", "exp": Date().timeIntervalSince1970 + 300]
        let header = ChatGPTOAuth.base64URL(Data(#"{"alg":"RS256","kid":"ephemeral-test-key"}"#.utf8))
        let payload = ChatGPTOAuth.base64URL(try JSONSerialization.data(withJSONObject: claims))
        let signed = Data((header + "." + payload).utf8)
        let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, nil)! as Data
        let token = header + "." + payload + "." + ChatGPTOAuth.base64URL(signature)
        let identity = try await ChatGPTIdentityVerifier.verify(token, clientID: "test-client", nonce: "nonce",
                                                                expectedSubject: nil, transport: transport)
        check("RS256 signature is verified against discovered JWK", identity.subject == "test-subject")
        var altered = signature
        altered[0] ^= 0xff
        await expectFailure("tampered signatures cannot activate an account") {
            _ = try await ChatGPTIdentityVerifier.verify(header + "." + payload + "." + ChatGPTOAuth.base64URL(altered),
                clientID: "test-client", nonce: "nonce", expectedSubject: nil, transport: transport)
        }
        await expectFailure("correct signature does not bypass nonce validation") {
            _ = try await ChatGPTIdentityVerifier.verify(token, clientID: "test-client", nonce: "wrong",
                                                        expectedSubject: nil, transport: transport)
        }
        await expectFailure("returning account cannot change subjects") {
            _ = try await ChatGPTIdentityVerifier.verify(token, clientID: "test-client", nonce: "nonce",
                                                        expectedSubject: "other-subject", transport: transport)
        }
        await expectFailure("discovery cannot redirect key lookup to an untrusted host") {
            _ = try await ChatGPTIdentityVerifier.verify(token, clientID: "test-client", nonce: "nonce", expectedSubject: nil,
                transport: { request in
                    let malicious = Data(#"{"issuer":"https://auth.openai.com","jwks_uri":"https://attacker.test/jwks"}"#.utf8)
                    return (malicious, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                })
        }
        try await testTokenLifecycle()
        print("OK: Native ChatGPT checks passed; no account credentials or paid requests used.")
    }

    @MainActor
    private static func testTokenLifecycle() async throws {
        print("ChatGPT token renewal and account lifecycle")
        let suite = "com.opensource.dictidy.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        func fixture(_ endpoint: TokenEndpoint, expired: Bool = true) throws -> (ChatGPTSignInService, MemoryVault) {
            let accounts = ["one", "two"].map {
                ChatGPTAccount(clientID: $0, subject: "subject-" + $0, email: "test@example.test", hasCredentials: true, planEnabled: true)
            }
            defaults.set(try JSONEncoder().encode(accounts), forKey: "chatgpt.accounts")
            defaults.set("one", forKey: "chatgpt.selectedAccount")
            let session: [String: Any] = ["accessToken": "old-access", "refreshToken": "old-refresh", "idToken": "test-id-token",
                "expiresAt": Date().addingTimeInterval(expired ? -1 : 3600).timeIntervalSinceReferenceDate,
                "scopes": ChatGPTOAuth.scopes.split(separator: " ").map(String.init)]
            let memory = MemoryVault()
            memory.data = try JSONSerialization.data(withJSONObject: ["one": session, "two": session])
            return (ChatGPTSignInService(defaults: defaults, credentialStore: memory.store,
                                        transport: { await endpoint.handle($0) }), memory)
        }

        let serialEndpoint = TokenEndpoint(pause: true)
        let (serial, serialVault) = try fixture(serialEndpoint)
        let first = Task { try await serial.authorized(accountID: "one") { $0 } }
        let second = Task { try await serial.authorized(accountID: "one") { $0 } }
        await serialEndpoint.waitForRequest()
        await serialEndpoint.resume()
        let values = try await [first.value, second.value]
        let requestCount = await serialEndpoint.requests
        check("concurrent requests share one refresh and atomically persist the replacement pair",
              values == ["fresh-access", "fresh-access"] && requestCount == 1
              && serialVault.contents["one"]?["accessToken"] as? String == "fresh-access"
              && serialVault.contents["one"]?["refreshToken"] as? String == "fresh-refresh")

        let switchingEndpoint = TokenEndpoint(pause: true)
        let (switching, switchingVault) = try fixture(switchingEndpoint)
        let pending = Task { try await switching.authorized(accountID: "one") { $0 } }
        await switchingEndpoint.waitForRequest()
        switching.selectAccount("two")
        await switchingEndpoint.resume()
        await expectFailure("switching accounts discards pending inference") { _ = try await pending.value }
        check("switching accounts preserves the completed rotation for the original account",
              switchingVault.contents["one"]?["refreshToken"] as? String == "fresh-refresh")
        switching.selectAccount("one")
        let resumed = try await switching.authorized(accountID: "one") { $0 }
        let switchingRequests = await switchingEndpoint.requests
        check("returning to an account reuses its saved renewed token", resumed == "fresh-access" && switchingRequests == 1)

        let logoutEndpoint = TokenEndpoint(pause: true)
        let (logout, logoutVault) = try fixture(logoutEndpoint)
        let active = Task { try await logout.authorized(accountID: "one") { $0 } }
        await logoutEndpoint.waitForRequest()
        let disconnect = Task { await logout.disconnect() }
        while !logout.isDisconnecting { await Task.yield() }
        check("sign-out immediately blocks new requests during a pending renewal", !logout.isConnected)
        await logoutEndpoint.resume()
        await disconnect.value
        await expectFailure("sign-out prevents a late renewal from producing inference") { _ = try await active.value }
        let revoked = await logoutEndpoint.revocations
        check("sign-out revokes the latest rotating token and preserves other accounts",
              logoutVault.contents["one"] == nil && logoutVault.contents["two"] != nil
              && revoked.count == 1 && revoked[0].contains("token=fresh-refresh"))

        let invalidEndpoint = TokenEndpoint(status: 400, body: #"{"error":"invalid_grant"}"#)
        let (invalid, invalidVault) = try fixture(invalidEndpoint)
        await expectFailure("terminal refresh failures require sign-in again") {
            _ = try await invalid.authorized(accountID: "one") { $0 }
        }
        check("terminal refresh failures clear unusable credentials without affecting another account",
              !invalid.isConnected && invalidVault.contents["one"] == nil && invalidVault.contents["two"] != nil)

        let temporaryEndpoint = TokenEndpoint(status: 503, body: #"{"error":"temporarily_unavailable"}"#)
        let (temporary, temporaryVault) = try fixture(temporaryEndpoint)
        await expectFailure("temporary refresh failures do not cause an inference request") {
            _ = try await temporary.authorized(accountID: "one") { _ in preconditionFailure("No inference on a failed refresh") }
        }
        check("temporary failures retain the renewable session", temporary.isConnected
              && temporaryVault.contents["one"]?["refreshToken"] as? String == "old-refresh")

        let retryEndpoint = TokenEndpoint()
        let (retry, _) = try fixture(retryEndpoint, expired: false)
        var attempts = 0
        let retried = try await retry.authorized(accountID: "one") { token in
            attempts += 1
            if attempts == 1 { throw ChatGPTError.request(401, nil, "Expired", nil) }
            return token
        }
        check("an inference 401 receives exactly one token refresh and retry", retried == "fresh-access" && attempts == 2)
        var rejectedAttempts = 0
        await expectFailure("repeated inference 401s do not create a refresh loop") {
            _ = try await retry.authorized(accountID: "one") { _ in
                rejectedAttempts += 1
                throw ChatGPTError.request(401, nil, "Denied", nil)
            }
        }
        check("unauthorized inference retries are bounded", rejectedAttempts == 2)
    }

    /// Read the exported PKCS#1 public key to build the test JWKS. Production constructs the key
    /// in the other direction, so the fixture exercises Security.framework's real DER parser.
    private static func rsaComponents(_ der: Data) -> (Data, Data) {
        let bytes = [UInt8](der)
        var index = 1
        func length() -> Int {
            let first = Int(bytes[index]); index += 1
            if first < 128 { return first }
            var count = 0
            for _ in 0..<(first & 0x7f) { count = count * 256 + Int(bytes[index]); index += 1 }
            return count
        }
        _ = length()
        func integer() -> Data {
            precondition(bytes[index] == 0x02); index += 1
            let count = length()
            let result = Data(bytes[index..<(index + count)].drop(while: { $0 == 0 }))
            index += count
            return result
        }
        return (integer(), integer())
    }
}
