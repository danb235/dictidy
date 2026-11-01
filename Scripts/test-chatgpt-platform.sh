#!/usr/bin/env bash
# Exercises native OAuth callback and Security.framework verification without user credentials.
set -euo pipefail
cd "$(dirname "$0")/.."

DICTIDY_TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$DICTIDY_TEST_DIR"' EXIT
DICTIDY_TEST_SDK="${SDKROOT:-$(xcrun --show-sdk-path)}"

swiftc -sdk "$DICTIDY_TEST_SDK" -emit-library -emit-module -module-name DictidyKit \
    Sources/DictidyKit/*.swift -o "$DICTIDY_TEST_DIR/libDictidyKit.dylib" \
    -emit-module-path "$DICTIDY_TEST_DIR/DictidyKit.swiftmodule"
swiftc -sdk "$DICTIDY_TEST_SDK" -parse-as-library -I "$DICTIDY_TEST_DIR" -L "$DICTIDY_TEST_DIR" -lDictidyKit \
    Sources/Dictidy/Services/ChatGPTHTTP.swift Sources/Dictidy/Services/ChatGPTCallbackServer.swift \
    Sources/Dictidy/Services/ChatGPTSignInService.swift Sources/Dictidy/Services/KeychainService.swift \
    Tests/ChatGPTPlatformTests.swift -o "$DICTIDY_TEST_DIR/ChatGPTPlatformTests"
"$DICTIDY_TEST_DIR/ChatGPTPlatformTests"
