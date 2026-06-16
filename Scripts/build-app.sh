#!/usr/bin/env bash
# Builds RewriteDB and assembles a runnable RewriteDB.app bundle (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_NAME="RewriteDB"
APP_DIR="$APP_NAME.app"

echo "==> Building (${CONFIG})..."
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
if [ ! -f "$BIN_PATH" ]; then
    echo "ERROR: Built binary not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "==> Assembling ${APP_DIR}..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

IDENTITY_CN="RewriteDB Self-Signed"
if security find-identity -p codesigning 2>/dev/null | grep -q "${IDENTITY_CN}"; then
    echo "==> Signing with stable identity '${IDENTITY_CN}' (grants survive rebuilds)..."
    codesign --force --deep --sign "${IDENTITY_CN}" --identifier com.opensource.rewritedb "${APP_DIR}"
else
    echo "==> Ad-hoc signing. NOTE: Accessibility/Keychain grants will reset on every rebuild."
    echo "    Run ./Scripts/setup-signing.sh once to fix this permanently."
    codesign --force --deep --sign - --identifier com.opensource.rewritedb "${APP_DIR}"
fi

echo "OK: Built ${APP_DIR}"
echo "  Launch it:  open ${APP_DIR}   (or ./Scripts/run.sh)"
echo "  Note: after the FIRST launch you must grant Accessibility access in"
echo "        System Settings > Privacy & Security > Accessibility."
