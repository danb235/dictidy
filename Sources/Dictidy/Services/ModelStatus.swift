import Foundation

/// Download / readiness status for an on-device model — shared by `WhisperModelStore` (the Whisper
/// speech model) and `LocalLLMModelStore` (the local rewrite model), so one set of UI (StatusBadge,
/// the wizard's `DownloadRow`, the tab rows) renders either.
enum ModelStatus: Equatable {
    case missing
    case downloading(Double)      // 0…1
    case ready(URL)
    case failed(String)
}
