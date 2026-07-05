---
name: release
description: >-
  Cut and publish a new Dictidy release. Curates best-practice, user-facing release notes from
  every change since the last tag, updates CHANGELOG.md, and pushes the version tag that triggers the
  Release workflow to build, sign, zip, and publish the GitHub Release — after which the app offers it
  via Check for Updates…. Use when asked to publish a release, ship a version, cut a tag, or enable
  in-app update.
argument-hint: "[<x.y.z> | patch | minor | major]"
---

# /release — cut and publish a Dictidy release

Running this publishes a new version. On a pushed `vX.Y.Z` tag, `.github/workflows/release.yml` runs
the tests, builds the arm64 `.app` stamped with the tag's version, self-signs, zips it, computes the
SHA-256, and creates the GitHub Release using **this version's `CHANGELOG.md` section as the notes**.
The running app then surfaces it through **Check for Updates…** (the in-app updater compares the running
`CFBundleShortVersionString` against the latest release and offers anything newer).

Your job in this skill is the part that needs judgment: **pick the right version and write clean notes
covering all the changes**, then push the tag. Everything downstream is automated.

## Argument

`$ARGUMENTS` (optional):

- empty → infer the bump from the changes (see **Versioning**) and propose it;
- `x.y.z` → use that exact version;
- `patch` / `minor` / `major` → bump the last tag accordingly.

## 1. Preconditions — check first; abort with a clear message if any fail

Never tag a broken or divergent tree.

- `git rev-parse --abbrev-ref HEAD` is `main`.
- `git status --porcelain` is empty (clean working tree).
- `git fetch origin`, then confirm `main` is level with `origin/main`. If behind/ahead, tell the user to
  reconcile first (pull/rebase) and stop.
- `gh auth status` succeeds.
- `swift run DictidyTests` passes — fail fast locally before publishing.

## 2. Gather every change since the last release

- Last tag: `git describe --tags --abbrev=0` (empty output ⇒ this is the first release).
- Commits: `git log --no-merges --pretty='- %s (%h)' <lasttag>..HEAD` (omit the range on the first
  release to list all history).
- Scope: `git diff --stat <lasttag>..HEAD`.
- Read the `## [Unreleased]` section of `CHANGELOG.md` — the curated running list, and your primary source.

## 3. Decide the version (Versioning)

SemVer, bumped from the last tag `vMAJOR.MINOR.PATCH`:

- **major** — any breaking / incompatible user-facing change.
- **minor** — new user-facing features or capabilities, no breakage (`### Added`).
- **patch** — only fixes / docs / internal changes (`### Fixed`, non-feature `### Changed`).

An explicit `$ARGUMENTS` version or keyword always wins over inference. **First release** with no
argument: default `1.0.0` — but if a locally-built app already reports that version and the goal is to
exercise in-app update now, pick the next patch instead and say why (an equal version won't prompt).

## 4. Write best-practice notes + update `CHANGELOG.md`

Reconcile the `[Unreleased]` list against the git log so **nothing user-facing is missed** and nothing
internal is noise:

- Group under **Added / Changed / Fixed / Removed / Security** (Keep a Changelog); drop empty groups.
- One bullet per change, **user-facing and in the imperative** — describe the impact, not the
  implementation. Merge duplicate commits; omit pure-internal churn (CI tweaks, refactors, test-only)
  unless it affects users.
- Then edit `CHANGELOG.md`: rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` (today, from
  `date +%Y-%m-%d`) holding the curated groups, and insert a fresh empty `## [Unreleased]` above it.
  Keep the header format **exactly** `## [X.Y.Z] - YYYY-MM-DD` — the Release workflow extracts the notes
  by matching `## [X.Y.Z]`.

## 5. Preview + confirm (this publishes — get an explicit go)

Show the user: the chosen **version**, the rendered **release notes**, and the **CHANGELOG diff**. State
plainly that continuing pushes a public tag that publishes the release. Wait for explicit approval. If
they want a different version or edits, apply them and re-preview.

## 6. Publish (only after approval, in this order)

```sh
git add CHANGELOG.md && git commit -m "release: vX.Y.Z"
git push origin main
git tag -a vX.Y.Z -m "Dictidy vX.Y.Z"   # annotated
git push origin vX.Y.Z                     # ← this triggers the Release workflow
```

## 7. Verify + report

- Find the run: `gh run list --workflow=Release --limit 1`, then `gh run watch <id> --exit-status`.
- On success: print the release URL (`gh release view vX.Y.Z --json url -q .url`) and confirm the app now
  offers this version under **Check for Updates…**.
- On failure: surface the failing step (`gh run view <id> --log-failed`) and stop — the tag is pushed, so
  fix forward (a follow-up commit + re-run, or delete the tag/release and re-cut) rather than leaving a
  half-published release.

## Notes

- Keep history linear: commit straight to `main` and fast-forward push; never a merge commit.
- The README release badge and download link track `releases/latest`, so they need no per-release edit.
- Signing is optional (`DICTIDY_SIGNING_P12` / `DICTIDY_SIGNING_PASSWORD` secrets). Absent them the release is
  ad-hoc/self-signed and users clear quarantine — the workflow already spells this out in the notes.
