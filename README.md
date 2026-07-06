# Dictidy

[![CI](https://github.com/danb235/dictidy/actions/workflows/ci.yml/badge.svg)](https://github.com/danb235/dictidy/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/danb235/dictidy?display_name=tag&sort=semver)](https://github.com/danb235/dictidy/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2013.3%2B%20(Apple%20Silicon)-blue)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Dictidy is a free, open-source macOS menu-bar app for voice dictation and text rewriting.

Select text in any app, press a hotkey, and Dictidy rewrites it in place. Or press a dictation hotkey,
speak, and Dictidy pastes the transcript at your cursor. Rewriting can use your Anthropic API key or an
optional on-device model. Speech-to-text always runs on your Mac.

**Quick links:** [Install](#install) | [First launch](#first-launch) | [Use Dictidy](#use-dictidy) | [Privacy](#privacy-and-storage) | [Build from source](#build-from-source)

---

## Install

**Most people should start here. No developer tools are required.**

### Requirements

- Apple Silicon Mac
- macOS 13.3 or later
- Optional: an [Anthropic API key](https://console.anthropic.com/settings/keys) for cloud rewriting
- Optional: about 2.5 GB for the local rewrite model and about 1.6 GB for the local dictation model

### Download and open

1. Download the latest app:
   [**Dictidy-macOS.zip**](https://github.com/danb235/dictidy/releases/latest/download/Dictidy-macOS.zip)
2. Unzip it and move **Dictidy.app** to **Applications**.
3. Clear macOS quarantine:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Dictidy.app
   ```
   You can also open the app once, dismiss the warning, then go to **System Settings -> Privacy &
   Security -> Open Anyway**.
4. Launch **Dictidy**. It appears in the menu bar, not the Dock.

Dictidy is self-signed and not notarized. That is why macOS shows the first-open warning. Releases use
a stable signing identity so Accessibility and Microphone permissions carry across app updates.

### Updates

Use **Check for Updates...** from the Dictidy menu-bar icon. The app downloads the latest release,
shows the release notes, installs it, and relaunches.

---

## First Launch

On first launch, Dictidy opens a setup wizard. It verifies each step before letting you continue, so you
do not have to guess whether macOS permissions, keys, or model downloads worked.

You can set up any mix of these:

- **Cloud rewriting:** add your Anthropic API key and choose a Claude model.
- **Local rewriting:** download the on-device rewrite model and rewrite without an API key.
- **Dictation:** download the Whisper model, grant Microphone access, and choose dictation shortcuts.

Dictidy also needs **Accessibility** access so it can copy selected text and paste the result back into
the app you were already using. After granting Accessibility, quit and relaunch Dictidy so macOS applies
the permission.

You can reopen setup anytime from **Dictidy menu -> Run Setup Again...**.

---

## Use Dictidy

### Rewrite selected text

1. Select text in any app.
2. Press **Shift-Command-R** for Auto Clean, or choose another instruction from the menu-bar icon.
3. Dictidy replaces the selected text with the rewritten version.

### Dictate by voice

1. Press your **Dictate** or **Dictate + Clean** shortcut.
2. Speak.
3. Press the shortcut again to stop.
4. Dictidy pastes the transcript at your cursor.

**Dictate** pastes the raw transcript. **Dictate + Clean** transcribes locally, then cleans the text
with your selected rewrite provider.

### Customize instructions

Open **Settings -> Instructions** to add, edit, reorder, duplicate, delete, or assign shortcuts to
instructions. Each instruction can have its own name, style prompt, and global hotkey.

### Recover previous work

Open **History...** from the menu to recover recent rewrites and dictations. History is local and capped
to the newest 100 entries.

---

## What Dictidy Does Well

- **Works anywhere you type.** Dictidy uses macOS copy and paste automation, so it works across Mail,
  Slack, Notes, browsers, editors, and most standard text fields.
- **Rewrites existing text.** Clean up rough notes, change tone, translate to English, or create your
  own instructions.
- **Dictates locally.** Speech-to-text uses Whisper on your Mac. Audio is not uploaded.
- **Runs without a subscription.** Dictidy is free and open source. You can use your own API key or
  download the local rewrite model.
- **Falls back when configured.** If both providers are set up, Dictidy can fall back from Claude to the
  local model when the network or API is unavailable.
- **Keeps setup visible.** The menu tells you what is missing and links directly to the relevant setup
  step.
- **Has no telemetry.** Dictidy does not collect analytics.

---

## Privacy and Storage

| Data | Where it goes |
|---|---|
| Dictation audio | Processed on-device, kept in memory, not written to disk |
| Whisper transcription | Produced on-device |
| Local rewrite text | Processed on-device when using the local rewrite model |
| Anthropic rewrite text | Sent to Anthropic only when you choose the Anthropic provider |
| API key | Stored in the macOS Keychain |
| Models | `~/Library/Application Support/Dictidy` |
| Settings and instructions | `UserDefaults` under `com.opensource.dictidy` |
| History | Local JSON in Application Support, newest 100 entries |

---

## How Dictidy Compares

| | Dictidy | Wispr Flow | superwhisper | Apple Dictation |
|---|---|---|---|---|
| Price | Free | Free tier, Pro paid | Free tier, Pro paid | Free |
| Open source | Yes | No | No | No |
| Dictation on-device | Yes | No | Yes | Yes |
| Cleanup | On-device or your Claude key | Cloud | Cloud or your key | No |
| Rewrite existing selected text | Yes | No | No | No |
| Works across apps | Yes | Yes | Yes | Yes |
| Telemetry | No | Yes | Optional | Optional |

Competitor details can change. This table reflects the project maintainer's understanding as of July
2026.

---

## Troubleshooting

### Hotkey does nothing

Make sure Dictidy has **Accessibility** access, then quit and relaunch it. macOS often requires a
relaunch before a new Accessibility grant applies.

### Permissions look enabled, but Dictidy says they are missing

macOS ties permissions to the app's code signature. If you switch between a release build and a source
build, or rebuild without stable signing, macOS can show a stale enabled toggle.

Reset and grant again:

```sh
tccutil reset Accessibility com.opensource.dictidy
tccutil reset Microphone com.opensource.dictidy
```

Then launch Dictidy and follow setup again. If this happens on every source rebuild, run
`./Scripts/setup-signing.sh` once before rebuilding.

### Dictidy cannot be opened

The downloaded app is self-signed but not notarized. Clear quarantine:

```sh
xattr -dr com.apple.quarantine /Applications/Dictidy.app
```

Or open it once, dismiss the warning, then approve it in **System Settings -> Privacy & Security ->
Open Anyway**.

### Local rewrite says the model is not installed

Open **Settings -> Rewrite**, set the primary provider to **Local (on-device)**, and click
**Download model**. The model is about 2.5 GB and downloads once.

### Dictation asks for the speech model

Open **Settings -> Dictation** and download the Whisper model. The model is about 1.6 GB and downloads
once. Dictation also needs Microphone access.

### No text selected

Make sure text is actually selected and that the current app supports standard copy and paste.

---

## Build From Source

This section is for contributors. If you only want to use Dictidy, install the prebuilt app above.
Source builds do not receive in-app updates.

### Requirements

- Xcode Command Line Tools: `xcode-select --install`
- Apple Silicon Mac
- macOS 13.3 or later

### Build and launch

```sh
git clone https://github.com/danb235/dictidy.git
cd dictidy
./Scripts/setup-signing.sh
./Scripts/build-app.sh
./Scripts/run.sh
```

`setup-signing.sh` creates a local self-signed signing identity. This keeps Accessibility and Keychain
grants stable across rebuilds. Without it, every rebuild gets a new ad-hoc signature and macOS may ask
for permissions again.

### Test

```sh
swift run DictidyTests
```

The test runner is dependency-free and works with Command Line Tools.

### Project Structure

```text
Sources/
  DictidyKit/        Pure models, prompts, API parsing, history, and diff logic
  Dictidy/           Menu-bar app, settings UI, permissions, services, dictation, local LLM
  DictidyTests/      Dependency-free test runner
Scripts/
  build-app.sh       Build and assemble Dictidy.app
  run.sh             Build if needed, then launch
  setup-signing.sh   Create a stable local signing identity
  uninstall.sh       Remove installed app state for a clean first-run test
Resources/
  Info.plist         App metadata, LSUIElement, microphone usage string
```

### Architecture Notes

| Concern | Implementation |
|---|---|
| App shell | SwiftUI `MenuBarExtra`, no Dock icon |
| Global hotkeys | [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) |
| Capture and replace | Synthetic Command-C, rewrite/transcribe, synthetic Command-V, then optional clipboard restore |
| Cloud rewriting | Anthropic Messages API and Models API via `URLSession` |
| Local rewriting | Qwen3-4B-Instruct via prebuilt `llama.cpp` XCFramework |
| Speech-to-text | Whisper `large-v3-turbo` via prebuilt `whisper.cpp` XCFramework |
| Audio capture | `AVAudioEngine` to 16 kHz mono samples |
| Launch at login | `SMAppService.mainApp` |

`KeyboardShortcuts` is pinned to 1.15.0 because newer releases use SwiftUI preview macros that require
full Xcode. Dictidy is intentionally buildable with Command Line Tools.

---

## Uninstall

To remove the installed app:

```sh
rm -rf /Applications/Dictidy.app
```

To remove all stored state too:

```sh
rm -rf ~/Library/"Application Support"/Dictidy
rm -f  ~/Library/Preferences/com.opensource.dictidy.plist
rm -rf ~/Library/Caches/com.opensource.dictidy
rm -rf ~/Library/HTTPStorages/com.opensource.dictidy
defaults delete com.opensource.dictidy 2>/dev/null || true
security delete-generic-password -s com.opensource.dictidy 2>/dev/null || true
tccutil reset Accessibility com.opensource.dictidy
tccutil reset Microphone com.opensource.dictidy
```

From a source checkout, you can run the full reset script:

```sh
./Scripts/uninstall.sh --dry-run
./Scripts/uninstall.sh
```

---

## Releasing

Maintainers publish releases by updating `CHANGELOG.md`, pushing a `vX.Y.Z` tag, and letting
`.github/workflows/release.yml` build, sign, zip, checksum, and publish the GitHub Release.

Release signing secrets are created with:

```sh
./Scripts/setup-ci-signing.sh
```

---

## Contributing

Contributions are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) and
[ARCHITECTURE.md](ARCHITECTURE.md). By participating, you agree to the
[Code of Conduct](CODE_OF_CONDUCT.md).

---

## Security

Your API key stays in the macOS Keychain. Dictation and local rewriting run on-device. Dictidy sends no
telemetry. To report a vulnerability, see [SECURITY.md](SECURITY.md).

---

## License

MIT, see [LICENSE](LICENSE).
