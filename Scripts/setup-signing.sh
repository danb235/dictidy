#!/usr/bin/env bash
# Creates a local, self-signed code-signing certificate so RewriteDB has a STABLE identity.
#
# Why: an ad-hoc signature (codesign --sign -) changes on every build, and macOS ties both
# the Accessibility grant and Keychain access to the binary's signature. With a stable
# self-signed identity, those grants survive rebuilds — you grant access once, not every build.
#
# This certificate is local-only and never leaves your Mac. It is NOT notarization and does
# not require an Apple Developer account.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY_CN="RewriteDB Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY_CN"; then
    echo "OK: signing identity '$IDENTITY_CN' already exists. Nothing to do."
    exit 0
fi

# Use macOS's built-in LibreSSL, not a Homebrew OpenSSL 3.x on PATH: OpenSSL 3 writes
# PKCS#12 with algorithms that macOS's `security import` cannot read ("MAC verification failed").
OPENSSL="/usr/bin/openssl"
[ -x "$OPENSSL" ] || OPENSSL="openssl"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = RewriteDB Self-Signed
[v3]
basicConstraints   = critical, CA:false
keyUsage           = critical, digitalSignature
extendedKeyUsage   = critical, codeSigning
CNF

echo "==> Generating self-signed code-signing certificate (valid 10 years)..."
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/openssl.cnf" >/dev/null 2>&1

# A non-empty transport password + legacy PBE algorithms produce a PKCS#12 that macOS's
# `security import` accepts (empty-password / modern-algorithm p12s fail MAC verification).
P12_PASS="rewritedb-transport"
"$OPENSSL" pkcs12 -export -out "$TMP/identity.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout "pass:$P12_PASS" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES

echo "==> Importing into your login keychain (so codesign can use it)..."
# -A lets codesign use the key without a per-build keychain prompt.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" -A >/dev/null

echo "OK: created signing identity '$IDENTITY_CN'."
echo "    Now run ./Scripts/build-app.sh — it will sign with this identity automatically."