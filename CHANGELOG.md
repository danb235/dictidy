# Changelog

All notable changes to Dictidy. Format: [Keep a Changelog](https://keepachangelog.com/);
versioning: [SemVer](https://semver.org/).

**Release flow:** the section for a version below is published verbatim as that version's GitHub
Release notes and shown in the app's "Update available" screen. To cut a release: move items from
**Unreleased** into a new `## [X.Y.Z] - YYYY-MM-DD` section, commit, then push tag `vX.Y.Z`.

## [Unreleased]

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
