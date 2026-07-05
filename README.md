# Dictidy

[![CI](https://github.com/danb235/dictidy/actions/workflows/ci.yml/badge.svg)](https://github.com/danb235/dictidy/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/danb235/dictidy?display_name=tag&sort=semver)](https://github.com/danb235/dictidy/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2013.3%2B%20(Apple%20Silicon)-blue)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Rewrite selected text — or **dictate by voice** — **anywhere on your Mac** with a keyboard shortcut.
Select text → press **⇧⌘R** → Claude rewrites it and pastes it back in place. Or hit your dictation
hotkey → speak → the transcription (optionally cleaned up by Claude) is pasted at your cursor.
Rewriting uses the Anthropic (Claude) API by default, or an optional **on-device model** (no API
key, fully offline); speech-to-text always runs **100% on-device** with Whisper.

<!-- Add a screenshot or short GIF here once captured, e.g.:
     ![Dictidy](docs/screenshot.png)
     The menu-bar icon + a rewrite in action + the onboarding wizard reads best. -->

Dictidy is an open-source reimagining of the (now abandoned) **RewriteCmd** app. It fixes the bug
that broke the original: when using the Claude API, **model IDs are no longer baked into the binary** —
the model list is fetched live from Anthropic, so it stays current automatically (retired models drop
off and new ones appear with no app update). It also goes further than the original with an optional
on-device model and voice dictation.

```
┌─────────────────┐   ⇧⌘R    ┌────────────────┐   rewrite    ┌────────────────────┐
│  Any macOS app  │ ───────▶ │     Dictidy     │ ───────────▶ │  Claude API        │
│ (selected text) │ ◀─────── │ (menu-bar app)  │ ◀─────────── │  ·or· local model  │
└─────────────────┘  paste   └────────────────┘   result      └────────────────────┘
```

---

## Contents

- [Features](#features) · [Requirements](#requirements) · [**Install**](#install-recommended) · [First run](#first-run) · [Usage](#usage)
- [How it works](#how-it-works) · [Project structure](#project-structure) · [Build from source](#build-from-source-contributors) · [Testing](#testing) · [Troubleshooting](#troubleshooting) · [Uninstall](#uninstall)
- [Contributing](#contributing) · [Security](#security) · [Releasing](#releasing-maintainers) · [License](#license)

## Features

- **Global hotkey rewrite** — works in any app (Mail, Slack, Notion, IDEs, browsers…).
- **Local rewrite option (offline, no API key)** — don't want to pay for the API? In Settings →
  **Rewrite**, set the primary provider to **Local (on-device)** and download a small model
  (**Qwen3-4B-Instruct**, Q4_K_M, ~2.5 GB) that runs entirely on your Mac via
  [llama.cpp](https://github.com/ggml-org/llama.cpp). Keep both configured and toggle anytime; the
  model loads on first use and unloads when idle to free memory.
- **Automatic fallback** — make Claude your primary and enable **Fall back to the other provider**;
  if Claude is unavailable (offline, rate-limited, or a server error) Dictidy transparently rewrites
  with the local model instead, so a rewrite never just fails when you're offline.
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
- **First-run onboarding wizard** — a guided window takes a new user from install to working in about
  a minute: choose Claude / on-device / both, then grant access, add a key, and download models with
  every step **verified live** (Continue unlocks only once the check actually passes). Re-runnable from
  the menu ("Run Setup Again…").
- **Animated menu-bar icon** — a custom **Equalizer** waveform that reads at a glance: idle · listening
  (bars bounce) · working (shimmer) · setup-needed (pulse) · error. A template image, so it adapts to
  light/dark menu bars and inverts on highlight.
- **Guided setup** — the menu lists exactly what's missing — for rewriting *and* dictation — with
  one-click fixes; a consistent status badge shows readiness across every screen.
- **In-app updates** — **Check for Updates…** downloads and installs new signed releases (showing the
  release notes first); permissions carry across updates.
- **Launch at login** toggle.
- Native Swift + SwiftUI menu-bar app. No Dock icon. No telemetry.

---

## Requirements

**To run the app** (the recommended [prebuilt install](#install-recommended)):

- An **Apple Silicon Mac** on **macOS 13.3 (Ventura) or later** — developed and used on macOS 15. (No Intel build.)
- An **Anthropic API key** for cloud rewriting and Dictate + Clean — **optional if you only use the
  on-device rewrite model** — <https://console.anthropic.com/settings/keys>.
- For **local (offline) rewriting**: a one-time **~2.5 GB** on-device model download (in-app). No API key needed.
- For **dictation**: a microphone and a one-time **~1.6 GB** Whisper model download (in-app).

**No developer tools are needed to run Dictidy.** Building from source additionally needs Xcode
**Command Line Tools** (full Xcode not required) — see [Build from source](#build-from-source-contributors).

---

## Install (recommended)

**This is how to get Dictidy — most people should start here.** Download the prebuilt, signed app;
no toolchain, no building. **Apple Silicon (arm64), macOS 13.3+.**

1. Download the latest **`Dictidy-vX.Y.Z.zip`** from the
   [**Releases**](https://github.com/danb235/dictidy/releases/latest) page and unzip it.
2. Move **Dictidy.app** to **/Applications**.
3. Dictidy is signed with a self-signed certificate but **not notarized** by Apple (it's free and
   open-source, with no paid Apple Developer account), so macOS quarantines it after download. Clear
   that once — in Terminal:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Dictidy.app
   ```
   …**or** double-click it, dismiss the "can't be opened" dialog, then go to **System Settings →
   Privacy & Security**, scroll to **Security**, and click **Open Anyway** (admin password).
   *(macOS Sequoia removed the old Control-click → Open shortcut.)*
4. Launch it — the **onboarding wizard** walks you through setup (see [First run](#first-run)).

**Updates are automatic.** Dictidy checks for new releases and offers a one-click **Check for
Updates…** (menu bar) that shows the release notes before installing — one click fetches and installs
it for you, and because releases share a stable signing identity, **your permissions carry over**.
(Optional: verify the download's SHA-256 against the release notes.)

> Prefer to build it yourself? See [Build from source](#build-from-source-contributors) — that path is
> for contributors and doesn't auto-update.

---

## First run

**The easiest path: the onboarding wizard opens automatically on first launch** and walks you through
everything below — choosing a rewrite provider, granting Accessibility, adding a key and/or downloading
models, and (optionally) setting up dictation — verifying each step as you go. You can reopen it anytime
from the menu bar → **Run Setup Again…**.

Prefer to do it manually? Equivalent steps:

1. **Grant Accessibility access.** Click the menu-bar icon → **Grant Accessibility access…**, enable
   **Dictidy**, then **quit and relaunch**. (Required to copy your selection and paste the result back.)
2. **Add your API key and pick a model.** Menu bar → **Settings… → Rewrite**, paste your key, **Save**
   (this also fetches the model list), then pick a model. *(Skip this if you'll only use the local
   rewrite model — see below.)*

The menu-bar icon settles into its idle Equalizer state once Accessibility + a usable provider are set.

**Optional — rewrite offline with no API key** (Settings → **Rewrite**): set the primary provider to
**Local (on-device)** and **Download model** (~2.5 GB, one time). Rewrites then run entirely on your
Mac — no key, no network. Both providers can be set up at once; switch the primary anytime, or enable
**Fall back to the other provider** to use the local model automatically whenever Claude is unavailable.

**Optional — set up dictation** (Settings → **Dictation**): (1) **Download** the Whisper model
(~1.6 GB, on-device), (2) **Grant Microphone** access, (3) **set a hotkey** for *Dictate* and/or
*Dictate + Clean*. Each step shows a ✓ when done, and the menu-bar icon only flags unfinished
dictation setup once you've started (a rewrite-only user is never nagged).

---

## Usage

**Rewrite selected text:**
1. Select text in any app.
2. Press **⇧⌘R** (Auto Clean), or pick an instruction from the menu-bar icon.
3. The selection is replaced in place with the rewrite — from Claude or the local model, whichever
   you've set as primary (the icon spins while it works).

**Dictate by voice:**
1. Press your **Dictate** or **Dictate + Clean** hotkey (Settings → Dictation). The menu-bar icon
   pulses while listening.
2. Speak, then press the hotkey again to stop. The icon spins while it transcribes on-device (and,
   for *Dictate + Clean*, runs the transcript through your rewrite provider — Claude or the local model).
3. The text is pasted at your cursor.

Add, edit, reorder, and assign shortcuts to instructions under **Settings → Instructions** — unlimited,
free. Recover any past rewrite or dictation from **History** (menu → History…).

---

## How it works

| Concern | Implementation |
|---|---|
| App shell | SwiftUI `MenuBarExtra` (macOS 13+), `LSUIElement` (no Dock icon) |
| Global hotkey | [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) (pinned to 1.15.0 — see note) |
| Capture / replace | Synthesize ⌘C to copy, run the rewrite (Claude API or on-device model), write result to the clipboard, synthesize ⌘V (then restore your clipboard) |
| API | Raw HTTPS via `URLSession` — `POST /v1/messages`, `GET /v1/models`, `anthropic-version: 2023-06-01` |
| Local rewriting | Optional on-device **Qwen3-4B-Instruct** (Q4_K_M) via the prebuilt [llama.cpp](https://github.com/ggml-org/llama.cpp) XCFramework — same CLT-friendly binary-target approach as Whisper (embedded Metal, no `metal` toolchain, GPU-accelerated); loads on first use, unloads when idle |
| API key storage | macOS Keychain (Security framework) |
| Settings persistence | `UserDefaults` (instructions, rewrite provider + fallback, selected model, cached model list, dictation prefs) |
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
  DictidyKit/        # Pure, dependency-free logic (unit-tested)
    Instruction.swift          # instruction model + seeded defaults
    AnthropicModel.swift       # model decoding + default-model selection
    AnthropicClient.swift      # Messages/Models API client + pure parsing helpers
    HistoryEntry.swift         # history model (kind + before/after) with legacy-safe decode
    RewriteProvider.swift      # rewrite backend selector (Anthropic API | local on-device) + fallback order
    RewritePrompt.swift        # wraps to-rewrite text as inert data (so a dictated request is cleaned, not answered)
    WordDiff.swift             # pure word-level LCS diff for the History before/after view
  Dictidy/           # The menu-bar app (UI, permissions, hotkeys, dictation, local LLM)
    DictidyApp.swift, AppState.swift
    Services/          # Keychain, RewriteService, LaunchAtLogin, Accessibility, ShortcutsRegistry, HistoryStore,
                       #   MicrophonePermissions, ModelStatus, WhisperEngine, WhisperModelStore, DictationService,
                       #   LocalLLMEngine, LocalLLMModelStore   (llama.cpp rewrite provider)
    Views/             # MenuBarContent, HistoryView, WaveformIcon (animated menu-bar glyph),
                       #   StatusBadge, OnboardingWizard, + Settings tabs (Rewrite / Instructions / Dictation / General)
  DictidyTests/      # Dependency-free test runner (`swift run DictidyTests`)
Scripts/
  setup-signing.sh     # one-time: create local signing identity (dev builds)
  setup-ci-signing.sh  # one-time: provision the CI release-signing secrets
  build-app.sh         # build + bundle (embeds whisper.framework + llama.framework) + sign Dictidy.app
  run.sh               # build if needed, then launch
Resources/Info.plist   # LSUIElement, bundle id, version, microphone usage string
```

---

## Build from source (contributors)

> **Most people don't need this** — [install the prebuilt app](#install-recommended) instead (it also
> auto-updates). This section is for hacking on Dictidy. Source builds use a *different* signing
> identity than releases and do **not** receive in-app updates.

Needs Xcode **Command Line Tools** (`xcode-select --install`) — **full Xcode is not required.**
One-liner — clone, set up signing, build, and launch:

```sh
git clone https://github.com/danb235/dictidy.git && cd dictidy && ./Scripts/setup-signing.sh && ./Scripts/build-app.sh && ./Scripts/run.sh
```

Or step by step:

```sh
git clone https://github.com/danb235/dictidy.git && cd dictidy
./Scripts/setup-signing.sh  # ONE TIME: local self-signed cert so permissions persist (see below)
./Scripts/build-app.sh      # compiles + assembles Dictidy.app (downloads deps on first run)
./Scripts/run.sh            # launches it (builds first if needed)
```

An Equalizer-waveform icon appears in your menu bar (no Dock icon); first launch opens the onboarding
wizard (see [First run](#first-run)). You can also `open Package.swift` in Xcode if you have the full
IDE installed.

### Why the self-signed certificate?

`./Scripts/setup-signing.sh` creates a **local, self-signed code-signing certificate** in your login
keychain (it never leaves your Mac; this is **not** notarization and needs **no** Apple Developer account).

It matters because macOS ties both the **Accessibility grant** and **Keychain access** to the app's exact
code signature. An *ad-hoc* signature (the default `codesign --sign -`) changes on **every rebuild**, so
each rebuild would silently revoke your permissions — the classic "the toggle is on but it still doesn't
work" symptom. A stable certificate fixes this permanently: the app's identity stays constant across
rebuilds, so you grant access **once**. (Your local dev identity is separate from the CI identity that
signs releases — so switching between a source build and an installed release re-grants once.)

---

## Testing

The pure logic (models, default selection, API response parsing, error extraction, the rewrite-input
framing) is covered by a small **dependency-free test runner** — XCTest and swift-testing aren't fully
usable without full Xcode, so the tests run anywhere `swift` does:

```sh
swift run DictidyTests
```

It exits non-zero on any failure, and runs on every push via GitHub Actions ([CI](.github/workflows/ci.yml)).

---

## Troubleshooting

- **Hotkey does nothing.** Make sure Dictidy has **Accessibility** access (menu bar → Grant…), then
  **quit and relaunch** — macOS only applies a new grant on relaunch. The menu-bar icon shows ⚠️ until
  it's ready.
- **Permissions look enabled but the app says they're missing (often right after an update or a rebuild).**
  macOS ties the grant to the app's code signature, so a signature change (e.g. a source build → an
  installed release, or a rebuild without a stable cert) can leave a stale "on" toggle that no longer
  applies. Toggle Dictidy **off then on** in System Settings → Privacy & Security → **Accessibility**
  (and **Microphone**), or reset and re-grant:
  ```sh
  tccutil reset Accessibility com.opensource.dictidy
  tccutil reset Microphone com.opensource.dictidy
  ```
  then **quit and relaunch**. Releases all share one identity, so update-to-update this won't recur. If
  it instead recurs on **every source rebuild**, you're building without a stable cert — run
  `./Scripts/setup-signing.sh` once (see [Build from source](#build-from-source-contributors)), rebuild,
  then reset and grant one final time.
- **"No text selected."** Ensure text is actually selected and the app supports ⌘C/⌘V.
- **Local rewrite says the model isn't installed.** Settings → **Rewrite** → set primary to
  **Local (on-device)** → **Download model** (~2.5 GB, one time). While it downloads, the menu-bar ⚠️
  + "To rewrite text" checklist shows the step; switch the primary back to **Anthropic API** anytime.
- **Dictation is greyed out / "Download speech model".** Open Settings → **Dictation** and download the
  Whisper model (~1.6 GB, one time). Dictation also needs **Microphone** access (Settings → Dictation →
  Grant…) — the menu-bar ⚠️ + "To dictate" checklist point you to whatever's missing.
- **"Dictidy can't be opened" (downloaded app).** It's self-signed but not notarized. Clear the
  quarantine flag — `xattr -dr com.apple.quarantine /Applications/Dictidy.app` — **or** open it once,
  then **System Settings → Privacy & Security → Open Anyway**. (Sequoia removed the Control-click → Open trick.)

---

## Uninstall

1. **Quit** Dictidy (menu bar → **Quit Dictidy**). If **Launch at login** is on, turn it off first
   (Settings → **General**) so no login item is left behind.
2. **Delete the app:**
   ```sh
   rm -rf /Applications/Dictidy.app     # …or wherever you keep it
   ```

That's all you need to stop using it. To also remove **everything it stored** — the on-device models
(several GB), history, settings, cached data, and your saved API key:

```sh
rm -rf ~/Library/"Application Support"/Dictidy          # models (~4 GB) + history
rm -f  ~/Library/Preferences/com.opensource.dictidy.plist   # settings, instructions, shortcuts
rm -rf ~/Library/Caches/com.opensource.dictidy
rm -rf ~/Library/HTTPStorages/com.opensource.dictidy
defaults delete com.opensource.dictidy 2>/dev/null || true  # UserDefaults (in case it's cached)
security delete-generic-password -s com.opensource.dictidy 2>/dev/null || true  # your Anthropic API key
```

Then revoke the macOS permission grants (removes the leftover **Dictidy** rows from System Settings):

```sh
tccutil reset Accessibility com.opensource.dictidy
tccutil reset Microphone com.opensource.dictidy
```

That's the complete footprint — Dictidy keeps no other state and sends no telemetry. *(If you also ran
it from source with `swift run`, dev builds additionally use a `Dictidy` UserDefaults domain:
`defaults delete Dictidy`.)*

---

## Releasing (maintainers)

**Easiest:** run the [`/release`](.claude/skills/release/SKILL.md) Claude Code skill (optionally
`/release <x.y.z|patch|minor|major>`). It curates the notes from every change since the last tag,
updates the CHANGELOG, shows a preview to approve, then pushes the tag and watches the workflow. Users
can then update in-app.

Or do it by hand:

1. Move the relevant `## [Unreleased]` items in [`CHANGELOG.md`](CHANGELOG.md) into a new
   `## [X.Y.Z] - YYYY-MM-DD` section and commit.
2. Tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`.
3. `.github/workflows/release.yml` runs the tests, builds + version-stamps `Dictidy.app`, zips it,
   and publishes a GitHub Release whose notes are that CHANGELOG section (+ install steps + SHA-256).

**One-time: stable release signing (recommended).** So the in-app updater's grants persist across
updates (macOS ties Accessibility/Microphone to the signing identity), releases are signed with a
stable self-signed identity stored as repo secrets `DICTIDY_SIGNING_P12` (base64) and
`DICTIDY_SIGNING_PASSWORD`. Provision (or later rotate) them with one command:
```sh
./Scripts/setup-ci-signing.sh   # generates the CI "Dictidy Self-Signed" identity + sets both secrets
```
Without these secrets the release still builds (ad-hoc signed) — but each update resets macOS
permissions, so users must re-grant. (`Scripts/setup-signing.sh` is the separate **local** identity for
your own `build-app.sh` dev builds; end users only ever see the CI identity above.)

---

## Website (maintainers)

The marketing site at **[dictidy.com](https://dictidy.com)** lives in [`site/`](site/) and deploys to
**Cloudflare Pages** (project `dictidy`) via [`.github/workflows/deploy-site.yml`](.github/workflows/deploy-site.yml).

- **`site/index.html`** is a single self-contained file (fonts and everything inlined, no external
  dependencies), exported from Claude Design as "Standalone HTML". To update the design, edit it there
  and re-export over `site/index.html`. `site/_headers` (security + cache headers), `robots.txt`,
  `sitemap.xml`, `favicon.svg`, and `og-image.png` round out the deploy.
- **Deploys** run only when `site/**` changes: push to `main` → production (dictidy.com); a PR that
  touches `site/` → a preview URL commented on the PR. No build step (it's static).

**One-time setup.** Create a Cloudflare Pages project named `dictidy` (Direct Upload) and a **scoped API
token** (`Account → Cloudflare Pages → Edit`, nothing else). Add them as **Environment secrets** on the
`production` and `preview` GitHub environments: `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`.
Attach the custom domain `dictidy.com` (+ a `www` → apex redirect) in the Pages project.

**Security (public repo).** GitHub secrets are write-only and are withheld from forked-PR runs; the
workflow uses `pull_request` (never `pull_request_target`) and guards the deploy job to same-repo
branches, so a fork PR can never run with the token. `main` is protected (PR + review, no direct
pushes), the `production` environment is restricted to `main` with a required reviewer, `v*` tags are
protection-ruled to maintainers, and [`CODEOWNERS`](.github/CODEOWNERS) requires review on
`.github/workflows/**` and `site/_headers`. The token is least-privilege (Pages-only) and revocable.

---

## Contributing

Contributions are welcome — see **[CONTRIBUTING.md](CONTRIBUTING.md)** for how to build (Command Line
Tools only), run the tests, and open a PR, and **[ARCHITECTURE.md](ARCHITECTURE.md)** for a tour of the
code. By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

---

## Security

Your API key stays in the macOS Keychain and is only sent to Anthropic; dictation and local rewriting
run entirely on-device; there's no telemetry. To report a vulnerability, see **[SECURITY.md](SECURITY.md)**.

---

## Credit

Inspired by the original **RewriteCmd** (rewritecmd.com). This is an independent, open-source rebuild
and is not affiliated with it.

## License

MIT — see [LICENSE](LICENSE).
