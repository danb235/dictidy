import Foundation

/// Provider-qualified identity prevents collisions and routes credentials to the right API.
public struct RewriteModel: Identifiable, Codable, Equatable, Sendable {
    public let provider: RewriteProvider
    public let modelID: String
    public let displayName: String
    /// Subscription catalogs belong to one account registration, even when model slugs match.
    public let connectionID: String?
    public var id: String {
        [provider.rawValue, connectionID, modelID].compactMap { $0 }.joined(separator: ":")
    }
    public var label: String { provider.displayName + " · " + displayName }

    public init(provider: RewriteProvider, modelID: String, displayName: String, connectionID: String? = nil) {
        self.provider = provider
        self.modelID = modelID
        self.displayName = displayName
        self.connectionID = connectionID
    }

    public static func migratedSelection(saved: String?, legacyAnthropicID: String?) -> String {
        if let saved { return saved }
        guard let legacyAnthropicID, !legacyAnthropicID.isEmpty else { return "" }
        return "anthropic:" + legacyAnthropicID
    }

    /// Preserve a usable selection across refreshes. Never select a provider whose key is absent.
    public static func resolvedSelection(_ saved: String, models: [RewriteModel],
                                         configuredProviders: Set<RewriteProvider>) -> String {
        let usable = models.filter { configuredProviders.contains($0.provider) }
        if usable.contains(where: { $0.id == saved }) { return saved }
        // Disconnecting a subscription must not silently select a separately billed API model.
        if saved.hasPrefix("chatgpt:") { return saved }
        if let sonnet = usable.first(where: { $0.provider == .anthropic && $0.modelID.contains("sonnet") }) {
            return sonnet.id
        }
        for preferred in ["gpt-6.1-sol", "gpt-6-sol", "gpt-5.6-sol", "gpt-5.5", "gpt-4.1", "gpt-4o"] {
            if let model = usable.first(where: { $0.provider == .openai && $0.modelID == preferred }) {
                return model.id
            }
        }
        return usable.first?.id ?? ""
    }
}
