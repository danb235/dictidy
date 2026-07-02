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

    /// The other provider (used to resolve the fallback).
    public var other: RewriteProvider {
        self == .anthropic ? .local : .anthropic
    }
}

/// The order in which to try providers for one rewrite: the primary first (if it's set up), then the
/// other provider (only if fallback is enabled and it's set up). Empty when nothing is usable —
/// callers treat that as "needs setup". Pure and side-effect-free so it's unit-testable.
public func rewriteProviderOrder(primary: RewriteProvider, fallbackEnabled: Bool,
                                 anthropicReady: Bool, localReady: Bool) -> [RewriteProvider] {
    func ready(_ p: RewriteProvider) -> Bool { p == .anthropic ? anthropicReady : localReady }
    var order: [RewriteProvider] = []
    if ready(primary) { order.append(primary) }
    if fallbackEnabled, ready(primary.other) { order.append(primary.other) }
    return order
}
