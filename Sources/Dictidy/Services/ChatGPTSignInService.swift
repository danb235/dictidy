import AppKit
import Combine
import CryptoKit
import Security
import DictidyKit

struct ChatGPTAccount: Codable, Identifiable, Equatable {
    let clientID: String
    var subject: String?
    var email: String?
    var hasCredentials = false
    var planEnabled = false
    var id: String { clientID }
    var label: String { (email ?? "ChatGPT account") + " · " + clientID.suffix(6) }
}

/// A single atomic vault. The injected version lets native tests exercise token rotation without
/// reading or writing the user's Keychain or account preferences.
struct ChatGPTCredentialStore {
    let load: () throws -> Data?
    let save: (Data) throws -> Void
    let delete: () throws -> Void
    let exists: () -> Bool
}

/// Owns Dictidy's OAuth credentials. Never reads another app's or Codex's login state.
@MainActor
final class ChatGPTSignInService: ObservableObject {
    static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    private static let keychainAccount = "chatgpt-credentials"
    private static let accountsKey = "chatgpt.accounts"
    private static let selectionKey = "chatgpt.selectedAccount"
    private static let hostKey = "chatgpt.hostID"

    @Published private(set) var accounts: [ChatGPTAccount] = []
    @Published private(set) var selectedAccountID: String?
    @Published private(set) var isSigningIn = false
    @Published private(set) var isDisconnecting = false
    @Published var message: String?
    @Published var showPlanConfirmation = false
    var onConnectionChanged: (() -> Void)?

    var selectedAccount: ChatGPTAccount? { accounts.first { $0.id == selectedAccountID } }
    var isConnected: Bool { selectedAccount.map { $0.hasCredentials && $0.planEnabled } ?? false }
    var isBusy: Bool { isSigningIn || isDisconnecting }

    private struct Session: Codable {
        let accessToken: String
        let refreshToken: String
        let idToken: String
        let expiresAt: Date
        let earliestRefreshAt: Date?
        let scopes: [String]
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let id_token: String?
        let token_type: String
        let expires_in: Double
        let scope: String?
        let earliest_refresh_at: Double?

        func session(previous: Session? = nil) throws -> Session {
            guard token_type.lowercased() == "bearer", !access_token.isEmpty, !refresh_token.isEmpty,
                  expires_in > 0, let idToken = id_token ?? previous?.idToken, !idToken.isEmpty else {
                throw ChatGPTError.invalidResponse("ChatGPT didn't return renewable sign-in credentials.")
            }
            return Session(accessToken: access_token, refreshToken: refresh_token, idToken: idToken,
                           expiresAt: Date().addingTimeInterval(expires_in),
                           earliestRefreshAt: earliest_refresh_at.map { Date(timeIntervalSince1970: $0) },
                           scopes: scope.map { $0.split(separator: " ").map(String.init) } ?? previous?.scopes ?? [])
        }
    }

    private struct OAuthFailure: LocalizedError {
        let code: String
        let status: Int
        var needsSignIn: Bool {
            ["invalid_grant", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"].contains(code)
        }
        var errorDescription: String? {
            needsSignIn ? "Your ChatGPT session has ended. Continue with ChatGPT in Settings → Rewrite to reconnect."
                : "ChatGPT sign-in failed (\(status), \(code)). Try connecting again."
        }
    }

    private let defaults: UserDefaults
    private let credentialStore: ChatGPTCredentialStore
    private let transport: OpenAIClient.Transport
    private var sessions: [String: Session]?
    private var loginTask: Task<Void, Never>?
    private var loginID: UUID?
    private var callbackServer: ChatGPTCallbackServer?
    private var refreshTasks: [String: (id: UUID, task: Task<Session, Error>)] = [:]
    private var connectionGeneration = UUID()

    init(defaults: UserDefaults = .standard, credentialStore: ChatGPTCredentialStore? = nil,
         transport: @escaping OpenAIClient.Transport = { try await ChatGPTHTTP.session.data(for: $0) }) {
        self.defaults = defaults
        self.transport = transport
        self.credentialStore = credentialStore ?? ChatGPTCredentialStore(
            load: {
                let data = KeychainService.load(account: Self.keychainAccount)
                if data == nil && KeychainService.exists(account: Self.keychainAccount) {
                    throw ChatGPTError.invalidResponse("Couldn't read your ChatGPT credentials from Keychain. Try connecting again.")
                }
                return data
            },
            save: { try KeychainService.save($0, account: Self.keychainAccount) },
            delete: { try KeychainService.delete(account: Self.keychainAccount) },
            exists: { KeychainService.exists(account: Self.keychainAccount) })
        if let data = defaults.data(forKey: Self.accountsKey),
           let saved = try? JSONDecoder().decode([ChatGPTAccount].self, from: data) { accounts = saved }
        selectedAccountID = defaults.string(forKey: Self.selectionKey)
        // Check presence without decrypting tokens or prompting for Keychain access at launch.
        if !self.credentialStore.exists() {
            for index in accounts.indices { accounts[index].hasCredentials = false }
        }
    }

    func selectAccount(_ id: String) {
        guard !isBusy, id != selectedAccountID, accounts.contains(where: { $0.id == id }) else { return }
        selectedAccountID = id
        message = nil
        connectionChanged()
    }

    func signIn(addAccount: Bool = false) {
        guard !isBusy else { return }
        let account = addAccount ? nil : selectedAccount
        let id = UUID()
        loginID = id
        isSigningIn = true
        message = nil
        loginTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.loginID == id {
                    self.callbackServer?.cancel()
                    self.callbackServer = nil
                    self.isSigningIn = false
                    self.loginTask = nil
                    self.loginID = nil
                }
            }
            do { try await self.performSignIn(account: account, attemptID: id) }
            catch is CancellationError { }
            catch {
                if self.loginID == id { self.message = error.localizedDescription }
            }
        }
    }

    func cancelSignIn() {
        loginTask?.cancel()
        callbackServer?.cancel()
        loginID = nil
        loginTask = nil
        callbackServer = nil
        isSigningIn = false
    }

    private func performSignIn(account: ChatGPTAccount?, attemptID: UUID) async throws {
        try Task.checkCancellation()
        guard loginID == attemptID else { throw CancellationError() }
        let state = try randomString()
        let nonce = try randomString()
        let verifier = try randomString()
        let challenge = ChatGPTOAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let server = ChatGPTCallbackServer(state: state, clientID: account?.clientID)
        callbackServer = server
        let callbackURL = try await server.start()
        try Task.checkCancellation()
        var hostID = defaults.string(forKey: Self.hostKey)
        if hostID == nil {
            hostID = "urn:uuid:" + UUID().uuidString.lowercased()
            defaults.set(hostID, forKey: Self.hostKey)
        }
        let previous = try account.flatMap { try loadSessions()[$0.id] }
        let authorizationURL = ChatGPTOAuth.authorizationURL(
            clientID: account?.clientID, hostID: hostID!, redirectURI: callbackURL, state: state,
            nonce: nonce, challenge: challenge, idTokenHint: previous?.idToken,
            requestConsent: account != nil && account?.planEnabled == false)
        guard NSWorkspace.shared.open(authorizationURL) else {
            throw ChatGPTError.invalidResponse("Couldn't open your browser for ChatGPT sign-in.")
        }
        let authorization = try await server.waitForCallback()
        try Task.checkCancellation()
        guard loginID == attemptID else { throw CancellationError() }
        // Retain newly issued registrations even if exchanging this one-time code fails.
        if !accounts.contains(where: { $0.id == authorization.clientID }) {
            accounts.append(ChatGPTAccount(clientID: authorization.clientID))
            persistAccounts()
        }
        let token = try await exchange([
            "grant_type": "authorization_code", "client_id": authorization.clientID,
            "code": authorization.code, "code_verifier": verifier,
            "redirect_uri": callbackURL.absoluteString, "resource": ChatGPTOAuth.resource
        ])
        let session = try token.session()
        let identity = try await ChatGPTIdentityVerifier.verify(session.idToken, clientID: authorization.clientID,
                                                               nonce: nonce, expectedSubject: account?.subject)
        try Task.checkCancellation()
        guard loginID == attemptID else { throw CancellationError() }
        var vault = try loadSessions()
        vault[authorization.clientID] = session
        try saveSessions(vault)
        let planEnabled = session.scopes.contains("chatgpt.tokens.use.direct")
        let index = accounts.firstIndex { $0.id == authorization.clientID }!
        accounts[index] = ChatGPTAccount(clientID: authorization.clientID, subject: identity.subject,
                                        email: identity.email, hasCredentials: true, planEnabled: planEnabled)
        selectedAccountID = authorization.clientID
        if planEnabled {
            let confirmationKey = "chatgpt.planConfirmed." + authorization.clientID
            showPlanConfirmation = !defaults.bool(forKey: confirmationKey)
            defaults.set(true, forKey: confirmationKey)
        } else {
            message = "Signed in, but ChatGPT plan usage wasn't enabled. Continue with ChatGPT to allow it."
        }
        connectionChanged()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// One bounded retry for a token that expires between checking it and sending the request.
    /// Account identity is captured by the model; an account switch cannot redirect pending work.
    func authorized<T>(accountID: String, operation: (String) async throws -> T) async throws -> T {
        let generation = connectionGeneration
        guard selectedAccountID == accountID, isConnected else { throw ChatGPTError.notConnected }
        let accessToken = try await validAccessToken(accountID: accountID)
        try Task.checkCancellation()
        guard generation == connectionGeneration else { throw CancellationError() }
        let result: T
        do { result = try await operation(accessToken) }
        catch let error as ChatGPTError where error.isUnauthorized {
            guard generation == connectionGeneration else { throw CancellationError() }
            let renewed = try await validAccessToken(accountID: accountID, force: true)
            try Task.checkCancellation()
            guard generation == connectionGeneration else { throw CancellationError() }
            result = try await operation(renewed)
        }
        guard generation == connectionGeneration else { throw CancellationError() }
        return result
    }

    private func validAccessToken(accountID: String, force: Bool = false) async throws -> String {
        guard let session = try loadSessions()[accountID] else { throw ChatGPTError.notConnected }
        if !force, session.expiresAt.timeIntervalSinceNow > 60 { return session.accessToken }
        if let earliest = session.earliestRefreshAt, earliest > Date(), session.expiresAt > Date() {
            return session.accessToken
        }
        let pending: (id: UUID, task: Task<Session, Error>)
        if let existing = refreshTasks[accountID] {
            pending = existing
        } else {
            pending = (UUID(), Task {
                let token = try await self.exchange([
                    "grant_type": "refresh_token", "client_id": accountID,
                    "refresh_token": session.refreshToken, "resource": ChatGPTOAuth.resource
                ])
                return try token.session(previous: session)
            })
            refreshTasks[accountID] = pending
        }
        defer { if refreshTasks[accountID]?.id == pending.id { refreshTasks[accountID] = nil } }
        do {
            let renewed = try await pending.task.value
            var vault = try loadSessions()
            // A selection change must not discard a rotated token. A newer sign-in or sign-out,
            // however, must never be overwritten by an older refresh finishing late.
            guard let current = vault[accountID],
                  current.refreshToken == session.refreshToken || current.refreshToken == renewed.refreshToken else {
                throw CancellationError()
            }
            vault[accountID] = renewed
            // Persist the rotating access/refresh token pair atomically before returning it.
            try saveSessions(vault)
            guard renewed.scopes.contains("chatgpt.tokens.use.direct") else {
                markDisconnected(accountID)
                throw ChatGPTError.notConnected
            }
            return renewed.accessToken
        } catch let error as OAuthFailure where error.needsSignIn {
            var vault = try loadSessions()
            if vault[accountID]?.refreshToken == session.refreshToken {
                vault[accountID] = nil
                try saveSessions(vault)
                markDisconnected(accountID)
                if selectedAccountID == accountID { message = error.localizedDescription }
            }
            throw error
        }
    }

    func disconnect() async {
        guard !isBusy, let account = selectedAccount else { return }
        isDisconnecting = true
        message = nil
        defer { isDisconnecting = false }
        do {
            // Stop new inference immediately. If renewal is already running, revoke its latest
            // refresh token rather than the now-consumed predecessor.
            markDisconnected(account.id)
            let renewed = try? await refreshTasks[account.id]?.task.value
            var vault = try loadSessions()
            let session = renewed ?? vault[account.id]
            vault[account.id] = nil
            try saveSessions(vault)
            guard let session else { return }
            // Remote revocation is best effort, but local sign-out has already stopped requests.
            let fields = ["token": session.refreshToken, "token_type_hint": "refresh_token", "client_id": account.id]
            var revoked = false
            for attempt in 0..<2 {
                if attempt > 0 { try await Task.sleep(nanoseconds: 500_000_000) }
                do {
                    let (_, response) = try await post("/api/accounts/oauth/revoke", fields: fields)
                    if (response as? HTTPURLResponse)?.statusCode == 200 { revoked = true; break }
                } catch { }
            }
            if !revoked { message = "Signed out locally. Remote sign-out wasn't confirmed; disconnect Dictidy in Manage usage." }
        } catch { message = error.localizedDescription }
    }

    private func markDisconnected(_ accountID: String) {
        if let index = accounts.firstIndex(where: { $0.id == accountID }) { accounts[index].hasCredentials = false }
        if selectedAccountID == accountID { connectionChanged() }
        else { persistAccounts() }
    }

    private func connectionChanged() {
        connectionGeneration = UUID()
        persistAccounts()
        onConnectionChanged?()
    }

    private func loadSessions() throws -> [String: Session] {
        if let sessions { return sessions }
        let decoded: [String: Session]
        if let data = try credentialStore.load() {
            decoded = try JSONDecoder().decode([String: Session].self, from: data)
        } else { decoded = [:] }
        sessions = decoded
        return decoded
    }

    private func saveSessions(_ vault: [String: Session]) throws {
        if vault.isEmpty { try credentialStore.delete() }
        else { try credentialStore.save(JSONEncoder().encode(vault)) }
        sessions = vault
    }

    private func persistAccounts() {
        if let data = try? JSONEncoder().encode(accounts) { defaults.set(data, forKey: Self.accountsKey) }
        defaults.set(selectedAccountID, forKey: Self.selectionKey)
    }

    private func exchange(_ fields: [String: String]) async throws -> TokenResponse {
        let (data, response) = try await post("/api/accounts/oauth/token", fields: fields)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = object?["error"] as? String ?? (object?["error"] as? [String: Any])?["code"] as? String ?? "request_failed"
            throw OAuthFailure(code: code, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func post(_ path: String, fields: [String: String]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: URL(string: ChatGPTOAuth.issuer + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = ChatGPTOAuth.form(fields)
        return try await transport(request)
    }

    private func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ChatGPTError.invalidResponse("Couldn't generate a secure sign-in request.")
        }
        return ChatGPTOAuth.base64URL(Data(bytes))
    }
}
