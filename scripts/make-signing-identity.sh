#!/usr/bin/env bash
# Create a local self-signed code-signing identity "heylisten-dev" in your login keychain.
# Builds signed with it keep a stable identity, so macOS keeps the Accessibility permission
# across rebuilds (ad-hoc signatures change every build).
#
# Remove it later with:  security delete-identity -c heylisten-dev
set -euo pipefail
name="heylisten-dev"
if security find-identity -p codesigning | grep -q "\"$name\""; then
  echo "$name already exists"; exit 0
fi
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cs.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
  -days 3650 -config "$tmp/cs.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" \
  -passout pass:heylisten 2>/dev/null
security import "$tmp/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P heylisten -T /usr/bin/codesign
echo "created $name; rebuild with scripts/build-app.sh (it picks the identity up automatically)"
