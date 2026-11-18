# Security Policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Instead, use GitHub's private reporting:
**Security → Report a vulnerability** on this repository
(<https://github.com/danb235/dictidy/security/advisories/new>), or contact the maintainer via their
GitHub profile ([@danb235](https://github.com/danb235)). We'll acknowledge within a few days and keep you
updated on a fix.

## Supported versions

Only the **latest release** is supported. Please upgrade (the app's **Check for Updates…** does this)
before reporting, in case the issue is already fixed.

## Security posture

Dictidy keeps voice transcription local and sends rewrite text to your chosen API provider:

- **API keys** are stored separately in the **macOS Keychain**. Anthropic keys are sent only to
  `api.anthropic.com`; OpenAI keys only to `api.openai.com`, over HTTPS. Keys are never logged,
  stored in preferences, or bundled into the app.
- **Voice transcription runs entirely on-device** with Whisper. Audio is held in memory, never
  written to disk, and never leaves your Mac. Dictate + Clean sends the transcript to the selected
  rewrite provider after local transcription.
- **Rewriting is online.** Selected text and configured instructions are sent to the provider of the
  selected model. OpenAI requests set `store: false`; the provider’s own logging and retention policies
  still apply. No conversation history or tools are sent.
- **No telemetry or analytics.** Network calls are to the configured Anthropic/OpenAI APIs (model
  catalogs and rewrites), Hugging Face / GitHub for the Whisper download, and GitHub for app updates.
- **Accessibility access** copies the selection, restores the destination window and control when
  you paste your last text again, and pastes the result (synthetic ⌘C/⌘V). Dictidy does not record keystrokes.

## A note on code signing

The app is **not notarized** and is signed with a self-signed (or ad-hoc) certificate — it's an
open-source project without a paid Apple Developer account. That's why macOS Gatekeeper asks you to
approve it on first launch (see the README's install steps). The in-app updater verifies a download's
code signature and bundle identifier before installing it, and each release publishes a SHA-256 you can
check against the downloaded archive.
