#!/bin/zsh
# Creates a self-signed code-signing certificate ("Splitwave Local") in your login keychain, so
# builds are signed with the same identity and macOS keeps Splitwave's audio permission across
# rebuilds. Run it once; macOS asks for your password to trust the certificate for code signing.
#   scripts/make-signing-cert.sh            create it
#   scripts/make-signing-cert.sh --remove   delete it again
set -euo pipefail
NAME="Splitwave Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [[ "${1:-}" == "--remove" ]]; then
  security delete-identity -c "$NAME" "$KEYCHAIN" && echo "Removed $NAME."
  exit 0
fi

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "$NAME already exists and is trusted for code signing."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
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
CNF

# /usr/bin/openssl (LibreSSL) writes a PKCS#12 that `security import` reads; Homebrew's OpenSSL 3 may not.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS=$(uuidgen)
/usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout "pass:$PASS"

security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
echo "Trusting the certificate for code signing (macOS asks for your password)…"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

security find-identity -v -p codesigning | grep "\"$NAME\"" >/dev/null && echo "Created $NAME. scripts/build-app.sh will use it."
