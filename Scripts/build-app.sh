#!/usr/bin/env bash
# Builds Dictidy and assembles a runnable Dictidy.app bundle (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_NAME="Dictidy"
APP_DIR="$APP_NAME.app"

# Host-arch build (arm64 on Apple Silicon). Universal (--arch arm64 --arch x86_64) is intentionally
# NOT used: it requires full Xcode's XCBuild, which the Command Line Tools lack, and Dictidy targets
# Apple Silicon (Metal-accelerated whisper/llama). The CI release runner is arm64, so releases are arm64.
echo "==> Building (${CONFIG})..."
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN_PATH="$BIN_DIR/$APP_NAME"
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
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"   # the equalizer logo (CFBundleIconFile)

# SwiftPM resource bundles (e.g. KeyboardShortcuts's localizations). SwiftPM packages with resources
# expose them via `Bundle.module`, which looks in the app's Contents/Resources. Assembling the .app by
# hand does NOT copy these, so without this every KeyboardShortcuts.Recorder crashes (Bundle.module
# traps when it can't find the bundle). Copy any *.bundle from the build dir into Resources.
for _rb in "$BIN_DIR"/*.bundle; do
    [ -e "$_rb" ] && cp -R "$_rb" "$APP_DIR/Contents/Resources/"
done

# Stamp the release version into the bundle (the release workflow sets DICTIDY_VERSION from the tag).
if [ -n "${DICTIDY_VERSION:-}" ]; then
    echo "==> Stamping version ${DICTIDY_VERSION}..."
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${DICTIDY_VERSION}" "$APP_DIR/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${DICTIDY_VERSION}" "$APP_DIR/Contents/Info.plist"
fi

# Embed the whisper.cpp and llama.cpp frameworks. They're SwiftPM binaryTargets, so they are NOT
# copied into the bundle automatically. Copy them into Contents/Frameworks and point @rpath there;
# the executable links them as @rpath/<name>.framework/Versions/Current/<name>.
echo "==> Embedding whisper.framework + llama.framework..."
mkdir -p "$APP_DIR/Contents/Frameworks"
cp -R "$BIN_DIR/whisper.framework" "$APP_DIR/Contents/Frameworks/"
cp -R "$BIN_DIR/llama.framework" "$APP_DIR/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null || true

IDENTITY_CN="Dictidy Self-Signed"
if security find-identity -p codesigning 2>/dev/null | grep -q "${IDENTITY_CN}"; then
    echo "==> Signing with stable identity '${IDENTITY_CN}' (grants survive rebuilds)..."
    codesign --force --deep --sign "${IDENTITY_CN}" --identifier com.opensource.dictidy "${APP_DIR}"
else
    echo "==> Ad-hoc signing. NOTE: Accessibility/Keychain grants will reset on every rebuild."
    echo "    Run ./Scripts/setup-signing.sh once to fix this permanently."
    codesign --force --deep --sign - --identifier com.opensource.dictidy "${APP_DIR}"
fi

echo "OK: Built ${APP_DIR}"
echo "  Launch it:  open ${APP_DIR}   (or ./Scripts/run.sh)"
echo "  Note: after the FIRST launch you must grant Accessibility access in"
echo "        System Settings > Privacy & Security > Accessibility."
