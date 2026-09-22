#!/bin/bash
# Creates a self-signed "IconCloak Dev" code-signing certificate in your login keychain.
#
# Signing local builds with a stable identity lets macOS keep the Accessibility permission
# across rebuilds. The certificate is only used by codesign on this Mac; no trust settings
# are changed. Remove it any time in Keychain Access.
set -euo pipefail

NAME="IconCloak Dev"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "'$NAME' already exists."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
PASS=$(openssl rand -hex 12)
# -legacy: macOS's keychain can't import OpenSSL 3's default PKCS#12 encryption.
LEGACY=$(openssl version | grep -q "^OpenSSL 3" && echo "-legacy" || true)
openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/cert.p12" -passout "pass:$PASS"
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P "$PASS" -T /usr/bin/codesign
echo "Created '$NAME'."
