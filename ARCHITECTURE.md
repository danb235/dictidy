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
  `ChatGPTSignInService` / `ChatGPTCallbackServer` / `ChatGPTHTTP`, and `Updater`.
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

**Provider configuration:** ChatGPT plan accounts and either or both API keys can be connected.
A single menu combines the configured providers’ model catalogs, with provider-qualified IDs so names
cannot collide. ChatGPT model IDs also include the issued account registration, so switching accounts
cannot redirect an instruction’s saved override. Each catalog refresh
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

**ChatGPT plan protocol:** `ChatGPTSignInService` implements the documented open-source public-client
OAuth flow with PKCE, state, nonce, a persistent opaque host ID, and a short-lived callback listener
bound to `127.0.0.1`. Dynamic registrations are saved per account/workspace. `ChatGPTIdentityVerifier`
verifies RS256 signatures using OpenAI discovery/JWKS and validates issuer, audience, expiry, nonce,
and the returning subject. Credentials live in one atomic Keychain vault, separate from API keys;
only account metadata and registration/host IDs are stored in UserDefaults. Refreshes are serialized,
rotating token pairs are saved together, and sign-out attempts refresh-token revocation.

`ChatGPTClient` calls the public `/v1/models` and `/v1/responses` endpoints using the account’s OAuth
access token. It parses the account-specific `models` catalog, retaining listed slugs, display names,
and server ordering. Requests send `instructions`, array `input`, `store: false`, and `stream: true`,
omitting unsupported API-key parameters such as `max_output_tokens`. HTTP/SSE transport lives in
`ChatGPTHTTP`, with ephemeral storage and redirects disabled. `ChatGPTResponseStream` accepts output
only after a valid `response.completed` event. Completed output items are retained because subscription
streams can leave the terminal output array empty; deltas, failures, and interrupted streams never paste.
A token-related 401 gets one refresh/retry. Account switches invalidate pending results and catalogs.
Disconnecting or losing a selected ChatGPT model retains its unavailable selection rather than
silently choosing separately billed API access. See the official
[sign-in contract](https://developers.openai.com/siwc/token-sharing-open-source/sign-in) and
[preview requirements](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations).
The manual acceptance checklist is in [CHATGPT_TESTING.md](docs/CHATGPT_TESTING.md).

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
