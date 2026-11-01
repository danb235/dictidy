# Changelog

All notable changes to Dictidy. Format: [Keep a Changelog](https://keepachangelog.com/);
versioning: [SemVer](https://semver.org/).

**Release flow:** the section for a version below is published verbatim as that version's GitHub
Release notes and shown in the app's "Update available" screen. To cut a release: move items from
**Unreleased** into a new `## [X.Y.Z] - YYYY-MM-DD` section, commit, then push tag `vX.Y.Z`.

## [Unreleased]

### Added
- **ChatGPT subscription connection.** Use Continue with ChatGPT in Rewrite settings or setup to
  connect an eligible Plus or Pro account, choose ChatGPT plan models, and manage usage. Tokens stay
  in Keychain and renew automatically. Saved accounts, sign-out, and API-key access remain separate.
  Incomplete responses never replace selected text, and plan failures never fall back to API billing.

## [2.2.0] - 2026-10-22

### Added
- **Copy Last Text.** Copy the latest rewrite or dictation to your clipboard from the top of the
  menu, above Paste Last Text. Use it with or without saved history, without generating again.

## [2.1.1] - 2026-10-22

### Changed
- **Paste Last Text comes first.** Recover the latest output from the top of the menu-bar menu.
- **Setup is in Settings.** Find Run Setup Again under Settings → General.
- **Simpler History label.** Open History directly from the menu without an ellipsis. Settings retains
  the standard macOS ellipsis.

## [2.1.0] - 2026-10-21

### Added
- **Choose a model per instruction.** Follow the default model from Rewrite settings or override it
  with a configured Anthropic or OpenAI model. The choice applies to menu actions, shortcuts,
  Dictate + Clean, and History's Rewrite again. Unavailable overrides stay saved and show a clear error
  instead of silently switching models.

### Fixed
- **Recover dictation when cleanup fails.** Validate the cleanup instruction's model before recording.
  If cleanup fails after transcription, recover the raw transcript through Paste Last Text and History
  when enabled. Cancelled work is still discarded.

## [2.0.0] - 2026-10-20

### Added
- **Paste Last Text.** Click in a text box, then choose Paste Last Text from the menu bar to retry
  the latest rewrite or dictation without opening History or generating again. The latest output
  stays available for the current session even with history off. Clipboard restoration still follows
  your setting.
- **OpenAI rewriting.** Save an OpenAI API key, an Anthropic API key, or both, then choose from one
  model menu. Refresh each provider's available models independently. Keys stay in separate macOS
  Keychain entries, and existing Anthropic model selections are preserved.

### Changed
- **Writing defaults.** Use Auto Clean to tidy dictated speech while keeping your voice, or Rewrite
  to compose a clearer professional message with more freedom over wording and flow. Upgrading
  retires untouched Formal, Friendly, and Translate to English presets. Custom instructions and
  existing Rewrite prompts are preserved.
- **Shared writing rules.** Preserve facts, uncertainty, greetings, signatures, and email paragraph
  breaks while letting each style control how much to change the wording. Keep ordinary hyphens and
  literal technical text; avoid em and en dashes in prose. Custom base instructions remain intact.

### Fixed
- **Settings access.** Reopen an already-running Dictidy app from Finder to show Settings, including
  when all of its windows are closed.
- **Permission recovery.** Find the permission controls on launch if macOS stops recognizing
  Dictidy's Accessibility or Microphone access after an app replacement. Use the menu's Microphone
  action to request fresh access when needed.

### Removed
- **Local rewriting and automatic provider fallback.** Configure an Anthropic or OpenAI API key for
  rewriting, including Dictate + Clean. On-device rewrite models and their downloads are no longer
  available. Whisper voice transcription and raw Dictate continue to run on your Mac without an API key.

## [1.2.1] - 2026-09-23

### Fixed
- **Paste works in remote desktop windows.** Dictating or rewriting inside Screen Sharing, Windows App
  (Microsoft Remote Desktop), and similar remote desktop apps now pastes your text instead of a single
  letter "v". Dictidy also waits for the clipboard to sync to the remote machine before pasting and
  before restoring your previous clipboard.

## [1.2.0] - 2026-07-22

### Added
- **Cancel dictation and rewrites with Escape.** Press Escape while recording, transcribing, or
  rewriting to discard the in-flight text. The menu-bar icon briefly flashes an X to confirm the
  cancellation was registered.

## [1.1.2] - 2026-07-06

### Fixed
- **Fixed the shortcut recorder crash in signed app bundles.** Opening Settings → Instructions or
  dictation shortcut setup no longer traps in the packaged app; shortcut recording now works from the
  signed release bundle.

## [1.1.1] - 2026-07-06

### Fixed
- **Fixed a crash when setting dictation shortcuts.** Opening the shortcut recorder (Reconfigure in
  Settings, Dictation, and the per-instruction shortcut fields) crashed the app because a bundled
  resource was missing from the packaged app. The app now includes it, so recording shortcuts works.

### Changed
- **Default dictation shortcuts.** When you set up dictation, Dictate + Clean is now bound to
  Control-Space and raw Dictate to Option-Space by default. You can change both in Settings, Dictation.

## [1.1.0] - 2026-07-05

### Added
- **App icon.** Dictidy now has a proper icon (the equalizer logo) in Finder, the app switcher, and
  when you drag it to Applications, in place of the generic blank icon.

### Changed
- **Reworked onboarding.** Dictation and rewriting are now set up as equal, first-class features. Each
  has its own step (Dictation, then Rewrite), followed by a single Permissions step. Nothing is labelled
  "optional": you turn a feature on, download its model right there, and continue once it is ready.
- **Editable base instructions, style-only modes.** A new base prompt holds the shared rules that every
  rewrite follows (return only the rewritten text, never use dashes, keep the meaning and language), so
  each instruction is now just its style. Auto Clean, Formal, Friendly, and Translate to English are
  rewritten as detailed, style-only prompts, with Formal, Friendly, and Translate now as thorough as
  Auto Clean. Edit the base under Settings, Instructions. Instructions you have customized are left
  untouched; unedited built-in ones update automatically.

## [1.0.0] - 2026-07-04

Initial release.

### Added
- **Rewrite anywhere** — select text in any app, press a global hotkey, and Claude (or an on-device
  model) rewrites it in place per your chosen instruction.
- **On-device voice dictation** — local Whisper (`large-v3-turbo`): **Dictate** (raw transcript) and
  **Dictate + Clean** (transcript tidied into clean text), pasted at your cursor. Audio never leaves your Mac.
- **Local on-device rewriting** — Qwen3-4B-Instruct via llama.cpp, as an offline / no-API-key
  alternative to the Claude API, with automatic fallback when the primary provider is unavailable.
- **Unlimited custom instructions** — each with its own name, system prompt, and global shortcut; seeded
  with Auto Clean (⇧⌘R), Formal, Friendly, and Translate to English.
- **History** with a word-level before/after diff and "Rewrite again".
- **First-run onboarding wizard** that verifies each setup step live.
- **Animated Equalizer menu-bar icon** (idle / listening / working / setup / error).
- **In-app updates** — Check for Updates… downloads and installs new signed releases, showing these
  notes first.
