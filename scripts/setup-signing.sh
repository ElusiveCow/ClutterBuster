#!/usr/bin/env bash
# One-time setup: creates a self-signed code-signing identity, "Clutter Buster Local Signing",
# in your login keychain. scripts/build-app.sh signs with it so every build has the same
# designated requirement, and macOS keeps the Desktop folder and Finder (Automation) grants
# you already allowed instead of asking again after each rebuild.
#
# Safe to run more than once; it does nothing if the identity already exists.
# Removing it: delete "Clutter Buster Local Signing" (certificate and key) in Keychain Access.
set -euo pipefail

NAME="Clutter Buster Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
    echo "Signing identity \"$NAME\" already exists."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -sha256 \
    -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

# Only protects the temporary .p12 file on its way into the keychain.
P12_PASSWORD="$(openssl rand -hex 16)"
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/identity.p12" -passout "pass:$P12_PASSWORD"

security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign

echo "Created signing identity \"$NAME\"."
security find-identity -p codesigning "$KEYCHAIN" | grep "\"$NAME\""
