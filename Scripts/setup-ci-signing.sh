#!/usr/bin/env bash
# Provision (or rotate) the CI code-signing identity used to sign Dictidy releases.
#
# Generates a fresh, dedicated self-signed "Dictidy Self-Signed" code-signing certificate and stores
# it as the two repo secrets the Release workflow (.github/workflows/release.yml) reads:
#   DICTIDY_SIGNING_P12       — the identity (.p12), base64-encoded
#   DICTIDY_SIGNING_PASSWORD  — that .p12's transport password
# Every release then signs with this one identity, so the in-app updater's macOS grants
# (Accessibility / Microphone) persist across version-to-version updates.
#
# This is the CI counterpart to Scripts/setup-signing.sh, which creates a LOCAL identity in your login
# keychain for `build-app.sh` dev builds. The two are independent identities; end users only ever see
# the CI one. The key generated here never touches your keychain and is scrubbed from disk on exit.
#
# ROTATION CAVEAT: running this again REPLACES the identity. The next release is then signed with a new
# identity, so already-installed apps re-grant permissions once on their next update. Only rotate when
# necessary (a lost or compromised key).
#
# Requires: gh (authenticated, repo-admin), /usr/bin/openssl (macOS LibreSSL).
set -euo pipefail

OPENSSL="/usr/bin/openssl"          # macOS LibreSSL — writes a p12 that `security import` can read
[ -x "$OPENSSL" ] || OPENSSL="openssl"

command -v gh >/dev/null || { echo "error: gh (GitHub CLI) is required." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: run 'gh auth login' first." >&2; exit 1; }

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
echo "Repo: $REPO"

# Guard against accidental rotation of an existing identity.
if gh secret list --repo "$REPO" | grep -q '^DICTIDY_SIGNING_P12'; then
    echo "!!  DICTIDY_SIGNING_P12 already exists. Rotating re-signs future releases with a NEW identity,"
    echo "    so installed apps re-grant macOS permissions once on their next update."
    read -r -p "Rotate the signing key? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted — nothing changed."; exit 0; }
fi

P12_PASS="$("$OPENSSL" rand -base64 18)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = Dictidy Self-Signed
[v3]
basicConstraints   = critical, CA:false
keyUsage           = critical, digitalSignature
extendedKeyUsage   = critical, codeSigning
CNF

echo "==> Generating self-signed code-signing certificate (valid 10 years)..."
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/openssl.cnf" >/dev/null 2>&1

# Legacy PBE so CI's `security import` can read the p12 (modern-algorithm p12s fail MAC verification).
"$OPENSSL" pkcs12 -export -out "$TMP/identity.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout "pass:$P12_PASS" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES

echo "==> Setting repo secrets on $REPO..."
base64 -i "$TMP/identity.p12" | gh secret set DICTIDY_SIGNING_P12 --repo "$REPO"
printf '%s' "$P12_PASS" | gh secret set DICTIDY_SIGNING_PASSWORD --repo "$REPO"

echo "OK: set DICTIDY_SIGNING_P12 + DICTIDY_SIGNING_PASSWORD on $REPO."
echo "    The next release (push a vX.Y.Z tag) will be signed with this identity."
