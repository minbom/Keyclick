#!/bin/bash
# Creates the local code-signing identity Keyclick is signed with, and trusts it
# for code signing in the login keychain. Idempotent: safe to re-run.
#
# Why this exists: an ad-hoc signature's designated requirement is the binary's
# own cdhash, so every rebuild produces a "new app" as far as TCC is concerned
# and the Input Monitoring grant is lost. Signing with a stable certificate makes
# the requirement certificate-based, so the grant survives rebuilds.
set -euo pipefail

cd "$(dirname "$0")"

IDENTITY="Keyclick Local Signing"
DIR=".signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
P12_PASS="keyclick"

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
	echo "already present: $IDENTITY"
	security find-identity -v -p codesigning | grep "$IDENTITY"
	exit 0
fi

mkdir -p "$DIR"

cat > "$DIR/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = $IDENTITY

[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "==> generating self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
	-config "$DIR/cert.cnf" \
	-keyout "$DIR/key.pem" \
	-out "$DIR/cert.pem" 2>/dev/null

# macOS Security.framework cannot read PKCS#12 files written with OpenSSL 3's
# modern defaults, so force the legacy PBE/MAC algorithms it understands.
echo "==> packaging as PKCS#12"
openssl pkcs12 -export \
	-out "$DIR/bundle.p12" \
	-inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
	-name "$IDENTITY" -passout "pass:$P12_PASS" \
	-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

echo "==> importing into the login keychain (may prompt for your password)"
security import "$DIR/bundle.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign -A

echo "==> trusting it for code signing only"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$DIR/cert.pem"

echo
security find-identity -v -p codesigning | grep "$IDENTITY" \
	|| { echo "FAILED: identity not usable for code signing" >&2; exit 1; }
echo "done. now run ./build.sh --install"
