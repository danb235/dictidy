import Foundation

/// Public-client OAuth mechanics. Randomness, hashing, signature verification, and the callback
/// listener live in the macOS service; these helpers never treat an unverified JWT as an identity.
public enum ChatGPTOAuth {
    public static let issuer = "https://auth.openai.com"
    public static let resource = "https://api.openai.com/v1"
    public static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

    public struct Authorization: Equatable, Sendable {
        public let code: String
        public let clientID: String
    }

    public static func authorizationURL(clientID: String?, hostID: String, redirectURI: URL,
                                        state: String, nonce: String, challenge: String,
                                        idTokenHint: String? = nil, requestConsent: Bool = false) -> URL {
        var parameters = [
            "client_id": clientID ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
            "response_type": "code", "redirect_uri": redirectURI.absoluteString, "scope": scopes,
            "resource": resource, "state": state, "nonce": nonce,
            "code_challenge_method": "S256", "code_challenge": challenge
        ]
        if clientID == nil { parameters["agent_name_hint"] = "Dictidy" }
        if let idTokenHint { parameters["id_token_hint"] = idTokenHint }
        if requestConsent { parameters["prompt"] = "consent" }
        var url = URLComponents(string: issuer + "/api/accounts/authorize")!
        url.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }

    public static func callback(_ url: URL, state: String, clientID: String?) throws -> Authorization {
        guard url.path == "/auth/callback", let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw ChatGPTError.invalidResponse("Unexpected sign-in callback.") }
        let items = components.queryItems ?? []
        // Reject duplicates rather than letting different parsers disagree about state or client identity.
        guard Set(items.map(\.name)).count == items.count,
              items.first(where: { $0.name == "state" })?.value == state else {
            throw ChatGPTError.invalidResponse("Sign-in state didn't match. Try connecting again.")
        }
        if items.contains(where: { $0.name == "error" }) {
            throw ChatGPTError.invalidResponse("ChatGPT sign-in was declined or couldn't be completed.")
        }
        let issuedID = items.first(where: { $0.name == "client_id" })?.value
        guard let resolvedID = issuedID ?? clientID, !resolvedID.isEmpty, resolvedID != "dynamic_agent_client",
              clientID == nil || resolvedID == clientID,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw ChatGPTError.invalidResponse("ChatGPT didn't return the expected client registration.")
        }
        return Authorization(code: code, clientID: resolvedID)
    }

    public static func form(_ fields: [String: String]) -> Data {
        // URLQueryItem does not escape literal '+', which form decoders interpret as a space.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "="
                + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func decodeBase64URL(_ value: String) -> Data? {
        let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }
}

public struct ChatGPTIDToken {
    public let keyID: String
    public let signedData: Data
    public let signature: Data
    private let claims: [String: Any]

    public init(_ token: String) throws {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let headerData = ChatGPTOAuth.decodeBase64URL(parts[0]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", header["crit"] == nil,
              let keyID = header["kid"] as? String, !keyID.isEmpty,
              let payload = ChatGPTOAuth.decodeBase64URL(parts[1]),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let signature = ChatGPTOAuth.decodeBase64URL(parts[2]), !signature.isEmpty else {
            throw ChatGPTError.invalidResponse("Invalid ChatGPT identity token.")
        }
        self.keyID = keyID
        self.claims = claims
        signedData = Data((parts[0] + "." + parts[1]).utf8)
        self.signature = signature
    }

    /// Call only after verifying signature against the issuer's JWKS.
    public func validateClaims(clientID: String, nonce: String, expectedSubject: String? = nil,
                               now: Date = Date()) throws -> (subject: String, email: String?) {
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard claims["iss"] as? String == ChatGPTOAuth.issuer, audiences.contains(clientID),
              (audiences.count == 1 || claims["azp"] as? String == clientID),
              let expiry = claims["exp"] as? Double, expiry > now.timeIntervalSince1970,
              (claims["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970 + 60,
              claims["nonce"] as? String == nonce,
              let subject = claims["sub"] as? String, !subject.isEmpty,
              expectedSubject == nil || expectedSubject == subject else {
            throw ChatGPTError.invalidResponse("ChatGPT identity verification failed. Try connecting again.")
        }
        return (subject, claims["email"] as? String)
    }
}
