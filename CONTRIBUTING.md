# Contributing to Dictidy

Thanks for your interest! Dictidy is a small, focused macOS menu-bar app. Bug reports, docs fixes,
and well-scoped features are all welcome. New here? Issues labeled **`good first issue`** are the
ideal place to start.

## Prerequisites

- **macOS 13.3+ on Apple Silicon.**
- **Xcode Command Line Tools** (`xcode-select --install`). **Full Xcode is not required.** The project
  builds with `swift build`; it deliberately avoids anything that needs the full IDE (see
  [`ARCHITECTURE.md`](ARCHITECTURE.md) for why `KeyboardShortcuts` is pinned and why whisper/llama ship
  as prebuilt XCFrameworks).

## Build & run

```sh
./Scripts/setup-signing.sh   # once: a local self-signed cert so macOS permissions persist across rebuilds
./Scripts/build-app.sh       # compiles + assembles Dictidy.app (downloads deps on first run)
./Scripts/run.sh             # launches it
```

See the README's [Build from source](README.md#build-from-source-contributors) section for the full
walkthrough, and [self-signed certificate](README.md#why-the-self-signed-certificate) for why that
first step matters (macOS ties Accessibility/Keychain grants to the code signature).

## Tests & coverage

```sh
swift run DictidyTests
```

Pure logic lives in the **`DictidyKit`** target and is unit-tested by the dependency-free runner in
`Sources/DictidyTests/main.swift` (XCTest isn't usable under CLT-only). **CI enforces a coverage floor
on `DictidyKit`** (currently ~99% lines). New pure logic belongs in `DictidyKit` with tests; keep it
covered. UI, permissions, audio, and the C-framework bindings live in the **`Dictidy`** app target and
are verified by the build plus manual testing; don't try to unit-test SwiftUI/AppKit.

## Code layout

- **`DictidyKit`**: pure, dependency-free logic (models, API parsing, provider selection, diffing).
  This is the unit-tested target and where testable logic should go.
- **`Dictidy`**: the menu-bar app itself: SwiftUI views, permissions, hotkeys, dictation, and the
  local LLM. Platform-bound, verified by building and manual testing.

## Code style

- Follow [`.editorconfig`](.editorconfig): spaces, 4-space Swift indent, LF, final newline, no trailing
  whitespace, ~120-col lines.
- Otherwise, **match the surrounding style**. The codebase is consistently hand-formatted. Keep comments
  explaining *why*, not *what*.

## Pull requests

1. Branch from `main`; keep PRs **small** and focused on one thing.
2. `swift run DictidyTests` passes and CI is green.
3. Update [`CHANGELOG.md`](CHANGELOG.md) under `## [Unreleased]` for any user-facing change.
4. We keep a **linear history**: rebase onto `main` rather than merging `main` into your branch.
5. Write clear, imperative commit messages ("Add X", "Fix Y"), one logical change each.

## Reporting bugs & requesting features

Open a [GitHub issue](https://github.com/danb235/dictidy/issues). For bugs, include your macOS version,
what you did, what you expected, and what happened (steps to reproduce help a lot). For feature
requests, describe the use case first, then the idea. Search open issues before filing to avoid
duplicates. Looking for somewhere to jump in? Browse the **`good first issue`** label.

## Releasing

Maintainers only, see the README's [Releasing](README.md#releasing-maintainers) section.
</content>
