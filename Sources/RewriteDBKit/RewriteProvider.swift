import Foundation

/// Which backend performs a rewrite.
/// - `anthropic`: the Claude API — requires an API key, pay-per-use, needs the network.
/// - `local`: an on-device LLM — no key, no network after a one-time model download.
///
/// The two can both be configured at once; the user flips between them in Settings → Model.
/// Anthropic is the default so a fresh install behaves exactly as before.
public enum RewriteProvider: String, Codable, CaseIterable {
    case anthropic
    case local

    /// Label for the Settings picker.
    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic API"
        case .local:     return "Local (on-device)"
        }
    }
}
