# RewriteDB

[![CI](https://github.com/danb235/rewritedb/actions/workflows/ci.yml/badge.svg)](https://github.com/danb235/rewritedb/actions/workflows/ci.yml)
[![Platform](https://img.shields.io/badge/platform-macOS%2013.3%2B-blue)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Rewrite selected text — or **dictate by voice** — **anywhere on your Mac** with a keyboard shortcut.
Select text → press **⇧⌘R** → Claude rewrites it and pastes it back in place. Or hit your dictation
hotkey → speak → the transcription (optionally cleaned up by Claude) is pasted at your cursor.
Rewriting uses the Anthropic (Claude) API by default, or an optional **on-device model** (no API
key, fully offline); speech-to-text always runs **100% on-device** with Whisper.

RewriteDB is an open-source, Anthropic-only reimagining of the (now abandoned) **RewriteCmd** app.
It fixes the bug that broke the original: **model IDs are no longer baked into the binary.** The
model list is fetched live from Anthropic, so it stays current automatically — retired models drop
off and new ones appear with no app update.

```
┌──────────────┐   ⇧⌘R    ┌───────────────┐   /v1/messages   ┌──────────┐
│ Any macOS app │ ───────▶ │   RewriteDB    │ ───────────────▶ │  Claude  │
│ (selected text)│ ◀─────── │ (menu-bar app) │ ◀─────────────── │   API    │
└──────────────┘  paste    └───────────────┘   rewritten text  └──────────┘
```

---

## Features

- **Global hotkey rewrite** — works in any app (Mail, Slack, Notion, IDEs, browsers…).
- **Local rewrite option (offline, no API key)** — don't want to pay for the API? Switch Settings →
  Model to **Local (on-device)** and download a small model (**Qwen3-4B-Instruct**, Q4_K_M, ~2.5 GB)
  that runs entirely on your Mac via [llama.cpp](https://github.com/ggml-org/llama.cpp). Keep both
  configured and toggle between Claude and local anytime; the model loads on first use and unloads
  when idle to free memory.
- **On-device voice dictation** — press a hotkey, speak, and the transcription pastes at your cursor.
  Powered by local **Whisper** (`large-v3-turbo`) via [whisper.cpp](https://github.com/ggml-org/whisper.cpp) —
  audio never leaves your Mac. Three actions: **Dictate** (raw transcript), **Dictate + Clean**
  (transcript → Claude cleanup → paste), and the classic **rewrite** of selected text.
- **History** — recover any past rewrite or dictation. Entries are badged by kind (Rewrite / Dictation /
  Dictation + Clean); copy the before, the after, or a transcript back to the clipboard. Local, newest 100.
- **Bring your own Anthropic API key** — stored in the macOS Keychain; only ever sent to `api.anthropic.com`.
- **Live, self-updating model list** — fetched from `GET /v1/models`; pick any current model, no app update needed.
- **Unlimited custom instructions** — each with its own name, system prompt, and global shortcut.
  Seeded with **Auto Clean** (⇧⌘R), **Formal**, **Friendly**, and **Translate to English**. No paywall.
- **Guided setup** — the menu-bar icon shows status (⚠️ setup needed · 🎙 listening · ↻ working · ready),
  and the menu lists exactly what's missing — for rewriting *and* dictation — with one-click fixes.
- **Launch at login** toggle.
- Native Swift + SwiftUI menu-bar app. No Dock icon. No telemetry.

---

## Requirements

- macOS 13.3 (Ventura) or later — built and used on macOS 15.
- Xcode **Command Line Tools** (`xcode-select --install`). **Full Xcode is not required.**
- An Anthropic API key — for cloud rewriting and Dictate + Clean (**optional if you only use the
  local rewrite model**) — <https://console.anthropic.com/settings/keys>.
- For **local (offline) rewriting**: a one-time **~2.5 GB model download** (in-app, on-device). No API key needed.
- For dictation: a microphone and a one-time **~1.6 GB Whisper model download** (in-app, on-device).

---

## Quick start

One-liner — clone, set up signing, build, and launch:

```sh
git clone https://github.com/danb235/rewritedb.git && cd rewritedb && ./Scripts/setup-signing.sh && ./Scripts/build-app.sh && ./Scripts/run.sh
```

Or step by step:

```sh
git clone https://github.com/danb235/rewritedb.git && cd rewritedb
./Scripts/setup-signing.sh  # ONE TIME: local self-signed cert so permissions persist (see below)
./Scripts/build-app.sh      # compiles + assembles RewriteDB.app (downloads deps on first run)
./Scripts/run.sh            # launches it (builds first if needed)
```

A speech-bubble icon appears in your menu bar (no Dock icon). You can also `open Package.swift` in Xcode
if you have the full IDE installed.

### First-time setup (one time)

1. **Grant Accessibility access.** On first launch macOS prompts you — or click the menu-bar icon →
   **Grant Accessibility access…**, enable **RewriteDB**, then **quit and relaunch**. (Required to copy
   your selection and paste the result back.)
2. **Add your API key.** Menu bar → **Settings… → API Key**, paste your key, **Save** (this also
   fetches the model list). *(Skip this if you'll only use the local rewrite model — see below.)*
3. **Pick a model.** Settings → **Model**. Use **Refresh Models** anytime to re-fetch the live list.

The menu-bar icon becomes a speech bubble once all three are done.

**Optional — rewrite offline with no API key** (Settings → **Model**): flip the provider to
**Local (on-device)** and **Download model** (~2.5 GB, one time). Rewrites then run entirely on your
Mac — no key, no network. Both providers can be set up at once; switch back to **Anthropic API** anytime.

**Optional — set up dictation** (Settings → **Dictation**): (1) **Download** the Whisper model
(~1.6 GB, on-device), (2) **Grant Microphone** access, (3) **set a hotkey** for *Dictate* and/or
*Dictate + Clean*. Each step shows a ✓ when done, and the menu-bar icon only flags unfinished
dictation setup once you've started (a rewrite-only user is never nagged).

---

## Usage

**Rewrite selected text:**
1. Select text in any app.
2. Press **⇧⌘R** (Auto Clean), or pick an instruction from the menu-bar icon.
3. The selection is replaced in place with Claude's rewrite (the icon spins while it works).

**Dictate by voice:**
1. Press your **Dictate** or **Dictate + Clean** hotkey (Settings → Dictation). The menu-bar icon
   pulses while listening.
2. Speak, then press the hotkey again to stop. The icon spins while it transcribes on-device (and,
   for *Dictate + Clean*, runs the transcript through Claude).
3. The text is pasted at your cursor.

Add, edit, reorder, and assign shortcuts to instructions under **Settings → Instructions** — unlimited,
free. Recover any past rewrite or dictation from **History** (menu → History…).

---

## Why the self-signed certificate?

`./Scripts/setup-signing.sh` creates a **local, self-signed code-signing certificate** in your login
keychain (it never leaves your Mac; this is **not** notarization and needs **no** Apple Developer account).

It matters because macOS ties both the **Accessibility grant** and **Keychain access** to the app's exact
code signature. An *ad-hoc* signature (the default `codesign --sign -`) changes on **every rebuild**, so
each rebuild would silently revoke your permissions — the classic "the toggle is on but it still doesn't
work" symptom. A stable certificate fixes this permanently: the app's identity stays constant across
rebuilds, so you grant access **once**.

---

## How it works

| Concern | Implementation |
|---|---|
| App shell | SwiftUI `MenuBarExtra` (macOS 13+), `LSUIElement` (no Dock icon) |
| Global hotkey | [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) (pinned to 1.15.0 — see note) |
| Capture / replace | Synthesize ⌘C to copy, call the API, write result to the clipboard, synthesize ⌘V (then restore your clipboard) |
| API | Raw HTTPS via `URLSession` — `POST /v1/messages`, `GET /v1/models`, `anthropic-version: 2023-06-01` |
| Local rewriting | Optional on-device **Qwen3-4B-Instruct** (Q4_K_M) via the prebuilt [llama.cpp](https://github.com/ggml-org/llama.cpp) XCFramework — same CLT-friendly binary-target approach as Whisper (embedded Metal, no `metal` toolchain, GPU-accelerated); loads on first use, unloads when idle |
| API key storage | macOS Keychain (Security framework) |
| Settings persistence | `UserDefaults` (instructions, rewrite provider, selected model, cached model list, dictation prefs) |
| Launch at login | `SMAppService.mainApp` |
| Live permission status | Polls `AXIsProcessTrusted()` **only while access is missing**, then stops |
| Speech-to-text | Local **Whisper** (`large-v3-turbo`) via the prebuilt [whisper.cpp](https://github.com/ggml-org/whisper.cpp) XCFramework — a SwiftPM binary target with a precompiled Metal library, so it builds under CLT (no `metal` toolchain) yet is GPU-accelerated at runtime |
| Audio capture | `AVAudioEngine` → 16 kHz mono via `AVAudioConverter`; kept in memory only, never written to disk |
| On-device models | Downloaded once to Application Support (Whisper ~1.6 GB; local rewrite model ~2.5 GB); fully offline afterward. Both load lazily and unload after ~4 min idle |
| History | Before/after (or transcript) of each action as JSON in Application Support (newest 100) |

> **KeyboardShortcuts is pinned to 1.15.0** because newer versions use the SwiftUI `#Preview` macro,
> whose macro plugin ships only with full Xcode — so `swift build` under the Command Line Tools can't
> expand it. 1.15.0 is the newest release without `#Preview` and has the full API used here.

---

## Project structure

```
Sources/
  RewriteDBKit/        # Pure, dependency-free logic (unit-tested)
    Instruction.swift          # instruction model + seeded defaults
    AnthropicModel.swift       # model decoding + default-model selection
    AnthropicClient.swift      # Messages/Models API client + pure parsing helpers
    HistoryEntry.swift         # history model (kind + before/after) with legacy-safe decode
    RewriteProvider.swift      # rewrite backend selector (Anthropic API | local on-device)
  RewriteDB/           # The menu-bar app (UI, permissions, hotkeys, dictation, local LLM)
    RewriteDBApp.swift, AppState.swift
    Services/          # Keychain, RewriteService, LaunchAtLogin, Accessibility, ShortcutsRegistry, HistoryStore,
                       #   MicrophonePermissions, WhisperEngine, WhisperModelStore, DictationService,
                       #   LocalLLMEngine, LocalLLMModelStore   (llama.cpp rewrite provider)
    Views/             # MenuBarContent, HistoryView + Settings tabs
                       #   (API Key / Model / Instructions / Dictation / General)
  RewriteDBTests/      # Dependency-free test runner (`swift run RewriteDBTests`)
Scripts/
  setup-signing.sh     # one-time: create local signing identity
  build-app.sh         # build + bundle (embeds whisper.framework + llama.framework) + sign RewriteDB.app
  run.sh               # build if needed, then launch
Resources/Info.plist   # LSUIElement, bundle id, version, microphone usage string
```

---

## Testing

The pure logic (models, default selection, API response parsing, error extraction) is covered by a
small **dependency-free test runner** — XCTest and swift-testing aren't fully usable without full
Xcode, so the tests run anywhere `swift` does:

```sh
swift run RewriteDBTests
```

It exits non-zero on any failure, and runs on every push via GitHub Actions ([CI](.github/workflows/ci.yml)).

---

## Troubleshooting

- **Hotkey does nothing.** Make sure RewriteDB has **Accessibility** access (menu bar → Grant…), then
  **quit and relaunch** — macOS only applies a new grant on relaunch. The menu-bar icon shows ⚠️ until
  it's ready.
- **Permissions reset after a rebuild?** You skipped `./Scripts/setup-signing.sh`. Run it once, rebuild,
  then `tccutil reset Accessibility com.opensource.rewritedb` and grant access one final time — it
  persists from then on.
- **"No text selected."** Ensure text is actually selected and the app supports ⌘C/⌘V.
- **Local rewrite says the model isn't installed.** Settings → **Model** → **Local (on-device)** →
  **Download model** (~2.5 GB, one time). While it downloads, the menu-bar ⚠️ + "To rewrite text"
  checklist shows the step; switch back to **Anthropic API** anytime to rewrite with Claude instead.
- **Dictation is greyed out / "Download speech model".** Open Settings → **Dictation** and download the
  Whisper model (~1.6 GB, one time). Dictation also needs **Microphone** access (Settings → Dictation →
  Grant…) — the menu-bar ⚠️ + "To dictate" checklist point you to whatever's missing.
- **Not notarized.** This is a local/personal build; the first launch of an unsigned-for-distribution
  app may require right-click → Open, or approval under System Settings → Privacy & Security.

---

## Credit

Inspired by the original **RewriteCmd** (rewritecmd.com). This is an independent, open-source rebuild
and is not affiliated with it.

## License

MIT — see [LICENSE](LICENSE).
