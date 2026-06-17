# RewriteDB

[![CI](https://github.com/danb235/rewritedb/actions/workflows/ci.yml/badge.svg)](https://github.com/danb235/rewritedb/actions/workflows/ci.yml)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Rewrite selected text **anywhere on your Mac** with one keyboard shortcut, using the Anthropic
(Claude) API. Select text → press **⇧⌘R** → it's rewritten and pasted back in place.

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
- **Bring your own Anthropic API key** — stored in the macOS Keychain; only ever sent to `api.anthropic.com`.
- **Live, self-updating model list** — fetched from `GET /v1/models`; pick any current model, no app update needed.
- **Unlimited custom instructions** — each with its own name, system prompt, and global shortcut.
  Seeded with **Auto Clean** (⇧⌘R), **Formal**, **Friendly**, and **Translate to English**. No paywall.
- **Guided setup** — the menu-bar icon shows status (⚠️ setup needed · spinning · **Aa** ready), and the
  menu lists exactly what's missing with one-click fixes.
- **Launch at login** toggle.
- Native Swift + SwiftUI menu-bar app. No Dock icon. No telemetry.

---

## Requirements

- macOS 13 (Ventura) or later — built and used on macOS 15.
- Xcode **Command Line Tools** (`xcode-select --install`). **Full Xcode is not required.**
- An Anthropic API key — <https://console.anthropic.com/settings/keys>.

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

A ✨/**Aa** icon appears in your menu bar (no Dock icon). You can also `open Package.swift` in Xcode
if you have the full IDE installed.

### First-time setup (one time)

1. **Grant Accessibility access.** On first launch macOS prompts you — or click the menu-bar icon →
   **Grant Accessibility access…**, enable **RewriteDB**, then **quit and relaunch**. (Required to copy
   your selection and paste the result back.)
2. **Add your API key.** Menu bar → **Settings… → API Key**, paste your key, **Save** (this also
   fetches the model list).
3. **Pick a model.** Settings → **Model**. Use **Refresh Models** anytime to re-fetch the live list.

The menu-bar icon turns into **Aa** once all three are done.

---

## Usage

1. Select text in any app.
2. Press **⇧⌘R** (Auto Clean), or pick an instruction from the menu-bar icon.
3. The selection is replaced in place with Claude's rewrite (spinner shows while it works).

Add, edit, reorder, and assign shortcuts to instructions under **Settings → Instructions** — unlimited,
free. Each menu entry shows its bound shortcut (or "no shortcut set").

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
| API key storage | macOS Keychain (Security framework) |
| Settings persistence | `UserDefaults` (instructions, selected model, cached model list) |
| Launch at login | `SMAppService.mainApp` |
| Live permission status | Polls `AXIsProcessTrusted()` **only while access is missing**, then stops |

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
  RewriteDB/           # The menu-bar app (UI, permissions, hotkeys)
    RewriteDBApp.swift, AppState.swift
    Services/          # Keychain, RewriteService, LaunchAtLogin, Accessibility, ShortcutsRegistry
    Views/             # MenuBarContent + Settings tabs (API Key / Model / Instructions / General)
  RewriteDBTests/      # Dependency-free test runner (`swift run RewriteDBTests`)
Scripts/
  setup-signing.sh     # one-time: create local signing identity
  build-app.sh         # build + bundle + sign RewriteDB.app
  run.sh               # build if needed, then launch
Resources/Info.plist   # LSUIElement, bundle id, version
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
- **Not notarized.** This is a local/personal build; the first launch of an unsigned-for-distribution
  app may require right-click → Open, or approval under System Settings → Privacy & Security.

---

## Credit

Inspired by the original **RewriteCmd** (rewritecmd.com). This is an independent, open-source rebuild
and is not affiliated with it.

## License

MIT — see [LICENSE](LICENSE).
