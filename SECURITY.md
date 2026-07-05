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

Dictidy is designed to keep your data local:

- **Your Anthropic API key** is stored in the **macOS Keychain** and is only ever sent to
  `api.anthropic.com` over HTTPS. It is never logged, transmitted elsewhere, or bundled into the app.
- **Voice dictation and local rewriting run entirely on-device** (Whisper + llama.cpp). Audio is held in
  memory only, never written to disk, and never leaves your Mac.
- **No telemetry or analytics.** The only network calls are to the Anthropic API (rewrites), the
  Hugging Face / GitHub download URLs for the on-device models, and the GitHub Releases API (update check).
- **Accessibility access** is used solely to copy the selection and paste the result (synthetic ⌘C/⌘V);
  nothing is recorded or inspected.

## A note on code signing

The app is **not notarized** and is signed with a self-signed (or ad-hoc) certificate — it's an
open-source project without a paid Apple Developer account. That's why macOS Gatekeeper asks you to
approve it on first launch (see the README's install steps). The in-app updater verifies a download's
code signature and bundle identifier before installing it, and each release publishes a SHA-256 you can
check against the downloaded archive.
