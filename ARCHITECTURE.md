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

- **`DictidyKit`** has no platform dependencies — `Instruction`, `RewriteModel`, `RewriteConfiguration`,
  `RewriteProvider`, `AnthropicModel`, `AnthropicClient`, `OpenAIClient` (both clients have injectable
  transports so request/error paths are testable), `HistoryEntry`, and `WordDiff`. This is where testable logic goes.
- **`Services`** wrap the OS: `AccessibilityPermissions`, `MicrophonePermissions`, `KeychainService`,
  `RewriteService` (the ⌘C-capture / ⌘V-paste dance), `ShortcutsRegistry` (global hotkeys),
  `DictationService` (`AVAudioEngine` → 16 kHz mono), `WhisperEngine`/`WhisperModelStore`,
  `ModelStatus` (speech model download state), `LaunchAtLogin`,
  and `Updater`.
- **`AppState`** owns published state, seeds defaults, drives the menu-bar icon animation counters,
  and orchestrates the flows below.

## Key flows

**Rewrite** (⇧⌘R or a menu instruction): `RewriteConfiguration` resolves the instruction's override or
the default model, capturing the instruction, model, and combined prompt → `RewriteService` copies the
selection (synthetic ⌘C) → `AppState.performRewrite` routes to that model's provider with its Keychain
credential → the result is retained for recovery, pasted (synthetic ⌘V, optionally restoring the clipboard),
and recorded to history when enabled.
Menu actions, shortcuts, History's Rewrite again, and Dictate + Clean share this resolution. Dictation
captures the configuration before recording and preserves the transcript for recovery if cleanup fails.
Unavailable overrides never switch models automatically.

**Provider configuration:** either or both API keys can be saved. A single menu combines the configured
providers’ model catalogs, with provider-qualified IDs so names cannot collide. Each catalog refresh
has its own status, error, and generation token; removing/replacing a key invalidates stale requests.
Existing Anthropic model selections and cached catalogs migrate without changing custom prompts.

**OpenAI protocol:** `GET /v1/models` uses Bearer authentication. Its catalog does not advertise
modality or endpoint support, so the app filters modern Responses text families and their fine-tunes,
excluding dedicated audio/image/search and specialist models. `POST /v1/responses` sends combined
base/style rules as `instructions`, source text as one user `input`, and `store: false`. It has no
conversation history or tools. Output text is collected from message content across the output array;
incomplete, refused, and empty responses are errors and never replace the source. The output budget
accounts for reasoning tokens and older model limits. See the official
[Responses text guide](https://developers.openai.com/api/docs/guides/text),
[model catalog API](https://developers.openai.com/api/reference/resources/models/methods/list), and
[reasoning guide](https://developers.openai.com/api/docs/guides/reasoning).

**Anthropic protocol:** `GET /v1/models` supplies the live Claude catalog; `POST /v1/messages` sends
the same combined rules as `system` and source text as one user message. Each API key is sent only to
its provider’s fixed HTTPS host.

**Dictation** (tap a hotkey): `DictationService` captures mic audio as 16 kHz mono in memory →
`WhisperEngine` transcribes on-device → the transcript is pasted (Dictate) or first cleaned through the
rewrite provider (Dictate + Clean). If cleanup has no instruction, or that instruction uses an unavailable
default model, Dictate + Clean pastes the raw transcript. An unavailable explicit model override blocks
recording instead.

## Why the unusual build choices

The dev machine has **Command Line Tools only (no full Xcode)**, which shapes two things:
- **whisper.cpp ships as a prebuilt XCFramework** (a SwiftPM binary target with embedded Metal),
  because CLT cannot compile its Metal shaders from source — speech transcription stays GPU-accelerated.
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
