import Foundation
import Network
import DictidyKit

/// A short-lived loopback listener bound specifically to 127.0.0.1, never all interfaces.
@MainActor
final class ChatGPTCallbackServer {
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var ready: CheckedContinuation<URL, Error>?
    private var callback: CheckedContinuation<ChatGPTOAuth.Authorization, Error>?
    private var result: Result<ChatGPTOAuth.Authorization, Error>?
    private var timeout: Task<Void, Never>?
    private let state: String
    private let clientID: String?

    init(state: String, clientID: String?) { self.state = state; self.clientID = clientID }

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .ready:
                    if let port = listener.port {
                        let continuation = self.ready
                        self.ready = nil
                        continuation?.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!)
                    }
                case .failed(let error): self.finish(.failure(error))
                default: break
                }
            }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000_000) }
            catch { return }
            self?.finish(.failure(ChatGPTError.invalidResponse("Sign-in timed out. Connect again when you're ready.")))
        }
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.start(queue: .main)
        }
    }

    func waitForCallback() async throws -> ChatGPTOAuth.Authorization {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { callback = $0 }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ outcome: Result<ChatGPTOAuth.Authorization, Error>) {
        guard result == nil else { return }
        result = outcome
        timeout?.cancel()
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        let pendingReady = ready
        ready = nil
        pendingReady?.resume(throwing: ChatGPTError.invalidResponse("Couldn't start the local sign-in callback."))
        let pendingCallback = callback
        callback = nil
        pendingCallback?.resume(with: outcome)
    }

    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        receive(connection, id: id, buffer: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                let buffer = buffer + (data ?? Data())
                if buffer.count > 16_384 || error != nil {
                    self.close(connection, id: id)
                } else if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.respond(connection, id: id, request: buffer)
                } else if complete {
                    self.close(connection, id: id)
                } else {
                    self.receive(connection, id: id, buffer: buffer)
                }
            }
        }
    }

    private func close(_ connection: NWConnection, id: UUID) {
        connections[id] = nil
        connection.cancel()
    }

    private func respond(_ connection: NWConnection, id: UUID, request: Data) {
        let firstLine = String(data: request, encoding: .utf8)?.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        let url = parts.count == 3 && parts[0] == "GET" && parts[1].hasPrefix("/")
            ? URL(string: "http://127.0.0.1" + parts[1]) : nil
        let outcome: Result<ChatGPTOAuth.Authorization, Error>
        do {
            guard let url else { throw ChatGPTError.invalidResponse("Invalid callback request.") }
            outcome = .success(try ChatGPTOAuth.callback(url, state: state, clientID: clientID))
        } catch {
            // Unrelated requests must not consume the real pending sign-in.
            let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            if url?.path == "/auth/callback", items.filter({ $0.name == "state" }).count == 1,
               items.first(where: { $0.name == "state" })?.value == state {
                outcome = .failure(error)
            } else {
                send(connection, id: id, status: "400 Bad Request", message: "Invalid sign-in callback.", outcome: nil)
                return
            }
        }
        let success = (try? outcome.get()) != nil
        send(connection, id: id, status: success ? "200 OK" : "400 Bad Request",
             message: success ? "Sign-in received. Return to Dictidy to finish connecting."
                              : "Sign-in couldn't be completed. Return to Dictidy and try again.", outcome: outcome)
    }

    private func send(_ connection: NWConnection, id: UUID, status: String, message: String,
                      outcome: Result<ChatGPTOAuth.Authorization, Error>?) {
        let body = "<!doctype html><meta charset=utf-8><title>Dictidy</title><p>\(message)</p>"
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((headers + body).utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                self?.close(connection, id: id)
                if let outcome { self?.finish(outcome) }
            }
        })
    }
}
