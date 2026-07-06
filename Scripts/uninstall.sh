#!/usr/bin/env bash
# Completely removes an installed Dictidy app and its user-level state.
# Mirrors README.md's Uninstall section so a fresh install shows first-run onboarding again.
set -euo pipefail

APP_ID="com.opensource.dictidy"
APP_NAME="Dictidy"

DRY_RUN=0
KEEP_APP=0
APP_PATHS=(
    "/Applications/Dictidy.app"
    "$HOME/Applications/Dictidy.app"
)

usage() {
    cat <<'USAGE'
Usage: ./Scripts/uninstall.sh [--dry-run] [--keep-app] [--app /path/to/Dictidy.app]

Options:
  --dry-run       Print what would be removed without changing anything.
  --keep-app      Remove Dictidy's stored state but leave app bundles in place.
  --app PATH      Also remove a specific installed Dictidy.app path.
  -h, --help      Show this help.

This removes the footprint documented in README.md:
  - installed app bundle(s) in /Applications and ~/Applications
  - Application Support models/history
  - preferences and UserDefaults domains
  - caches and HTTP storage
  - saved Anthropic API key from Keychain
  - Accessibility and Microphone permission grants

It intentionally does not remove the local repo build at ./Dictidy.app.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            ;;
        --keep-app)
            KEEP_APP=1
            ;;
        --app)
            if [ "$#" -lt 2 ]; then
                echo "ERROR: --app requires a path." >&2
                exit 2
            fi
            APP_PATHS+=("$2")
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'DRY RUN:'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

remove_path() {
    local path="$1"
    if [ -e "$path" ] || [ -L "$path" ]; then
        run rm -rf "$path"
    elif [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY RUN: skip missing $path"
    fi
}

echo "==> Quitting Dictidy if it is running..."
run osascript -e "tell application id \"$APP_ID\" to quit" 2>/dev/null || true
if [ "$DRY_RUN" -eq 0 ]; then
    sleep 0.5
fi
run pkill -x "$APP_NAME" 2>/dev/null || true

echo "==> Removing Launch at Login item if present..."
run osascript -e "tell application \"System Events\" to delete every login item whose name is \"$APP_NAME\"" 2>/dev/null || true

if [ "$KEEP_APP" -eq 0 ]; then
    echo "==> Removing installed app bundle(s)..."
    for app_path in "${APP_PATHS[@]}"; do
        remove_path "$app_path"
    done
else
    echo "==> Keeping app bundle(s) because --keep-app was passed."
fi

echo "==> Removing stored models, history, settings, and caches..."
remove_path "$HOME/Library/Application Support/Dictidy"
remove_path "$HOME/Library/Preferences/$APP_ID.plist"
remove_path "$HOME/Library/Caches/$APP_ID"
remove_path "$HOME/Library/HTTPStorages/$APP_ID"

echo "==> Removing UserDefaults domains..."
run defaults delete "$APP_ID" 2>/dev/null || true
run defaults delete "$APP_NAME" 2>/dev/null || true

echo "==> Removing saved API key from Keychain..."
run security delete-generic-password -s "$APP_ID" 2>/dev/null || true

echo "==> Resetting macOS permission grants..."
run tccutil reset Accessibility "$APP_ID" 2>/dev/null || true
run tccutil reset Microphone "$APP_ID" 2>/dev/null || true

echo "OK: Dictidy has been removed from this user account."
