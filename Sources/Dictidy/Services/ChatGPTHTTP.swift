import Foundation
import Security
import DictidyKit

/// Keep OAuth tokens out of cookies, caches, and redirects. All destinations are fixed HTTPS URLs.
enum ChatGPTHTTP {
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }()

    static func stream(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (lines, response)
    }
}

enum ChatGPTIdentityVerifier {
    /// Discovery pins the issuer and keys to OpenAI; never accept a JWT-supplied key URL.
    static func verify(_ rawToken: String, clientID: String, nonce: String,
                       expectedSubject: String?,
                       transport: OpenAIClient.Transport = { try await ChatGPTHTTP.session.data(for: $0) }) async throws
        -> (subject: String, email: String?) {
        let token = try ChatGPTIDToken(rawToken)
        let (discoveryData, discoveryResponse) = try await transport(
            URLRequest(url: URL(string: ChatGPTOAuth.issuer + "/.well-known/openid-configuration")!, timeoutInterval: 20))
        guard (discoveryResponse as? HTTPURLResponse)?.statusCode == 200,
              let discovery = try JSONSerialization.jsonObject(with: discoveryData) as? [String: Any],
              discovery["issuer"] as? String == ChatGPTOAuth.issuer,
              let keyURI = discovery["jwks_uri"] as? String, let keyURL = URL(string: keyURI),
              keyURL.scheme == "https", keyURL.host == "auth.openai.com", keyURL.port == nil,
              keyURL.user == nil, keyURL.password == nil else {
            throw ChatGPTError.invalidResponse("Couldn't verify OpenAI's sign-in configuration.")
        }
        let (keysData, keysResponse) = try await transport(URLRequest(url: keyURL, timeoutInterval: 20))
        struct KeySet: Decodable {
            struct Key: Decodable { let kid: String; let kty: String; let n: String?; let e: String?; let alg: String?; let use: String? }
            let keys: [Key]
        }
        guard (keysResponse as? HTTPURLResponse)?.statusCode == 200,
              let keys = try? JSONDecoder().decode(KeySet.self, from: keysData),
              let key = keys.keys.first(where: { $0.kid == token.keyID && $0.kty == "RSA"
                  && ($0.alg == nil || $0.alg == "RS256") && ($0.use == nil || $0.use == "sig") }),
              let n = key.n.flatMap(ChatGPTOAuth.decodeBase64URL), (256...1024).contains(n.count),
              let e = key.e.flatMap(ChatGPTOAuth.decodeBase64URL), !e.isEmpty, e.count <= 8 else {
            throw ChatGPTError.invalidResponse("Couldn't find OpenAI's identity signing key.")
        }
        let der = asn1(0x30, asn1Integer(n) + asn1Integer(e))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                       kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let publicKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                    token.signedData as CFData, token.signature as CFData, nil) else {
            throw ChatGPTError.invalidResponse("ChatGPT's identity signature wasn't valid.")
        }
        return try token.validateClaims(clientID: clientID, nonce: nonce, expectedSubject: expectedSubject)
    }

    private static func asn1Integer(_ bytes: Data) -> Data {
        var unsigned = Data(bytes.drop(while: { $0 == 0 }))
        if unsigned.isEmpty || unsigned[unsigned.startIndex] & 0x80 != 0 { unsigned.insert(0, at: unsigned.startIndex) }
        return asn1(0x02, unsigned)
    }

    private static func asn1(_ tag: UInt8, _ value: Data) -> Data {
        var length = value.count
        var bytes: [UInt8] = []
        repeat { bytes.insert(UInt8(length & 0xff), at: 0); length >>= 8 } while length > 0
        let prefix = value.count < 128 ? Data([UInt8(value.count)]) : Data([0x80 | UInt8(bytes.count)] + bytes)
        return Data([tag]) + prefix + value
    }
}
