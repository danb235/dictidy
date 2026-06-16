import Foundation

/// A model returned by Anthropic's `GET /v1/models` endpoint. Fetched live so the
/// picker always reflects current models — no app update needed when models change.
public struct AnthropicModel: Identifiable, Codable, Equatable, Hashable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? id
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

/// Envelope for `GET /v1/models`.
struct AnthropicModelsResponse: Codable {
    let data: [AnthropicModel]
}

extension AnthropicModel {
    /// Picks a sensible default model id from a live list: prefer a Sonnet (good speed/quality
    /// balance for a rewrite tool), else the first available, else an empty string.
    public static func preferredDefault(from models: [AnthropicModel]) -> String {
        if let sonnet = models.first(where: { $0.id.contains("sonnet") }) {
            return sonnet.id
        }
        return models.first?.id ?? ""
    }
}
