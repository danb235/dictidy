# Changelog

All notable changes to RewriteDB. Format: [Keep a Changelog](https://keepachangelog.com/);
versioning: [SemVer](https://semver.org/).

**Release flow:** the section for a version below is published verbatim as that version's GitHub
Release notes and shown in the app's "Update available" screen. To cut a release: move items from
**Unreleased** into a new `## [X.Y.Z] - YYYY-MM-DD` section, commit, then push tag `vX.Y.Z`.

## [Unreleased]

### Added
- **Local on-device rewriting** — Qwen3-4B-Instruct via llama.cpp, as an offline / no-API-key
  alternative to the Claude API, with automatic fallback when the primary provider is unavailable.
- **On-device voice dictation** — local Whisper (`large-v3-turbo`): Dictate, Dictate + Clean.
- **First-run onboarding wizard** that verifies each setup step live.
- **Animated Equalizer menu-bar icon** (idle / listening / working / setup / error).
- **History** with a word-level before/after diff and "Rewrite again".
- **In-app updates** — Check for Updates… downloads and installs new releases, showing these notes first.

### Changed
- Settings consolidated into **Rewrite / Instructions / Dictation / General**, with a shared status badge.
