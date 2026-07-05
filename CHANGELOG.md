# Changelog

All notable changes to Dictidy. Format: [Keep a Changelog](https://keepachangelog.com/);
versioning: [SemVer](https://semver.org/).

**Release flow:** the section for a version below is published verbatim as that version's GitHub
Release notes and shown in the app's "Update available" screen. To cut a release: move items from
**Unreleased** into a new `## [X.Y.Z] - YYYY-MM-DD` section, commit, then push tag `vX.Y.Z`.

## [Unreleased]

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
