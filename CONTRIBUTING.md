# Contributing to RewriteDB

Thanks for your interest! RewriteDB is a small, focused macOS menu-bar app. Bug reports, docs fixes,
and well-scoped features are all welcome.

## Prerequisites

- **macOS 13.3+ on Apple Silicon.**
- **Xcode Command Line Tools** (`xcode-select --install`) — **full Xcode is not required**. The project
  builds with `swift build`; it deliberately avoids anything that needs the full IDE (see
  [`ARCHITECTURE.md`](ARCHITECTURE.md) for why `KeyboardShortcuts` is pinned and why whisper/llama ship
  as prebuilt XCFrameworks).

## Build & run

```sh
./Scripts/setup-signing.sh   # once: a local self-signed cert so macOS permissions persist across rebuilds
./Scripts/build-app.sh       # compiles + assembles RewriteDB.app (downloads deps on first run)
./Scripts/run.sh             # launches it
```

See the README's [self-signed certificate](README.md#why-the-self-signed-certificate) section for why
that first step matters (macOS ties Accessibility/Keychain grants to the code signature).

## Tests & coverage

```sh
swift run RewriteDBTests
```

Pure logic lives in the **`RewriteDBKit`** target and is unit-tested by the dependency-free runner in
`Sources/RewriteDBTests/main.swift` (XCTest isn't usable under CLT-only). **CI enforces a coverage floor
on `RewriteDBKit`** (currently ~99% lines). New pure logic belongs in `RewriteDBKit` with tests; keep it
covered. UI, permissions, audio, and the C-framework bindings live in the app target and are verified by
the build + manual testing — don't try to unit-test SwiftUI/AppKit.

## Code style

- Follow [`.editorconfig`](.editorconfig): spaces, 4-space Swift indent, LF, final newline, no trailing
  whitespace, ~120-col lines.
- Otherwise, **match the surrounding style** — the codebase is consistently hand-formatted. Keep comments
  explaining *why*, not *what*.

## Pull requests

1. Branch from `main`; keep PRs small and focused on one thing.
2. `swift run RewriteDBTests` passes and CI is green.
3. Update [`CHANGELOG.md`](CHANGELOG.md) under `## [Unreleased]` for any user-facing change.
4. We keep a **linear history** — rebase onto `main` rather than merging `main` into your branch.
5. Write clear, imperative commit messages ("Add X", "Fix Y"), one logical change each.

## Releasing

Maintainers only — see the README's [Releasing](README.md#releasing-maintainers) section.
