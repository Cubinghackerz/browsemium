#!/usr/bin/env bash
#
# Creates a stable, self-signed code-signing identity for local development.
#
# Why this exists: macOS ties keychain access to the app's code signature. An
# ad-hoc signature ("-") changes on every build, so macOS treats each rebuild
# as a different app and re-asks for permission to use WebKit's
# "<App> WebCrypto Master Key" item. Signing with a certificate gives the app a
# stable designated requirement, so the permission sticks.
#
# The identity is local-only: it is not trusted by Gatekeeper and is useless for
# distribution. Notarized releases still need a Developer ID.
#
# IMPORTANT: macOS will ask for the login keychain password the first time
# codesign uses this key ("codesign wants to sign using key ..."). That password
# is the same one used to unlock the Mac. Without it the build fails with
# errSecInternalComponent, so only run this if you know that password — ad-hoc
# signing ("-") needs no authorization and is the default.
#
# Usage:
#   Scripts/create-dev-signing-identity.sh
#
# To undo:
#   security delete-identity -c "Browsemium Local Dev" \
#     ~/Library/Keychains/login.keychain-db
set -euo pipefail

IDENTITY_NAME="Browsemium Local Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "${IDENTITY_NAME}"; then
  echo "Signing identity '${IDENTITY_NAME}' already exists."
  exit 0
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required." >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# A code-signing certificate: digitalSignature key usage and the codeSigning
# extended key usage are what codesign looks for.
cat > "$WORKDIR/openssl.cnf" <<'CONFIG'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = Browsemium Local Dev
O = Browsemium
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" \
  -config "$WORKDIR/openssl.cnf" >/dev/null 2>&1

openssl pkcs12 -export -legacy \
  -inkey "$WORKDIR/key.pem" -in "$WORKDIR/cert.pem" \
  -out "$WORKDIR/identity.p12" -passout pass:browsemium \
  -name "${IDENTITY_NAME}" >/dev/null 2>&1

# -A and -T put this key in an access list codesign can use without a prompt.
# Setting the partition list instead would require the login keychain password,
# which must never be passed on a command line. This identity is local-only and
# is not trusted by Gatekeeper, so the wider ACL does not widen what it can do.
security import "$WORKDIR/identity.p12" -k "$KEYCHAIN" -P browsemium \
  -A -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "Created signing identity '${IDENTITY_NAME}'."
security find-identity -v -p codesigning "$KEYCHAIN" | grep "${IDENTITY_NAME}" || true
