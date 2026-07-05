# Architecture

A contributor's tour of how Dictidy is put together. For build/test instructions see
[CONTRIBUTING.md](CONTRIBUTING.md); for the user-facing overview see the [README](README.md).

## Shape

Dictidy is a SwiftUI **menu-bar app** (`MenuBarExtra`, `LSUIElement` — no Dock icon), built as a
Swift Package (`swift build`, no `.xcodeproj`). Three layers:

```
Sources/
  DictidyKit/   ── pure, dependency-free logic (unit-tested; the only unit-testable target)
  Dictidy/      ── the app
    Services/     ── platform integrations (permissions, Keychain, audio, model engines, updater)
    Views/        ── SwiftUI (menu, settings tabs, history, onboarding, the animated icon)
    AppState.swift ── the @MainActor ObservableObject hub that wires it all together
  DictidyTests/ ── dependency-free test runner (XCTest isn't available under CLT-only)
```

- **`DictidyKit`** has no platform dependencies — `Instruction`, `AnthropicModel`, `AnthropicClient`
  (with an injectable transport so its request/error paths are testable), `HistoryEntry`,
  `RewriteProvider` + `rewriteProviderOrder`, and `WordDiff`. This is where testable logic goes.
- **`Services`** wrap the OS: `AccessibilityPermissions`, `MicrophonePermissions`, `KeychainService`,
  `RewriteService` (the ⌘C-capture / ⌘V-paste dance), `ShortcutsRegistry` (global hotkeys),
  `DictationService` (`AVAudioEngine` → 16 kHz mono), `WhisperEngine`/`WhisperModelStore`,
  `LocalLLMEngine`/`LocalLLMModelStore`, `ModelStatus` (shared download state), `LaunchAtLogin`,
  and `Updater`.
- **`AppState`** owns published state, seeds defaults, drives the menu-bar icon animation counters,
  and orchestrates the flows below.

## Key flows

**Rewrite** (⇧⌘R or a menu instruction): `RewriteService` copies the selection (synthetic ⌘C) →
`AppState.performRewrite` runs it through the provider order from `rewriteProviderOrder` (primary, then
the fallback if enabled and the primary hit an *availability* error — see
`AnthropicError.isAvailabilityFailure`) → the result is recorded to history and pasted (synthetic ⌘V,
restoring the clipboard).

**Dictation** (tap a hotkey): `DictationService` captures mic audio as 16 kHz mono in memory →
`WhisperEngine` transcribes on-device → the transcript is pasted (Dictate) or first cleaned through the
rewrite provider (Dictate + Clean).

## Why the unusual build choices

The dev machine has **Command Line Tools only (no full Xcode)**, which shapes two things:
- **whisper.cpp and llama.cpp ship as prebuilt XCFrameworks** (SwiftPM binary targets with embedded
  Metal), because CLT can't compile their Metal shaders from source — yet they stay GPU-accelerated.
- **`KeyboardShortcuts` is pinned to 1.15.0** — newer versions use the SwiftUI `#Preview` macro, whose
  plugin ships only with full Xcode.

## Permissions & signing

macOS ties both the Accessibility (TCC) grant and Keychain access to the app's **code signature**.
`Scripts/setup-signing.sh` creates a stable self-signed identity so grants survive rebuilds; releases
are signed with a stable identity too, so upgrades keep their grants.

## Update & release loop

`release.yml` (on a `vX.Y.Z` tag) builds + version-stamps `Dictidy.app`, zips it, and publishes a
GitHub Release whose notes come from the matching `CHANGELOG.md` section. `Updater` polls the GitHub
Releases API, shows those notes, then downloads → verifies (codesign + bundle id) → swaps the bundle →
relaunches.

## Testing

`DictidyKit` is unit-tested by `Sources/DictidyTests/main.swift` (a plain executable — XCTest isn't
usable under CLT). CI instruments that run with `-profile-generate` and enforces a coverage floor via
`llvm-cov`. UI / audio / C-framework code is verified by the build succeeding + manual testing.
