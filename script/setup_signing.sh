#!/usr/bin/env bash
# One stable code-signing identity. Ad-hoc signatures change every rebuild and
# macOS then treats Accessibility as not granted, even when the switch is on.
set -euo pipefail

IDENTITY_NAME="DS Codex SSH Signing"
KEYCHAIN="$HOME/Library/Keychains/ds-codex-ssh.keychain-db"
KEYCHAIN_PASS="dscodexssh"

identity_ok() {
  security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY_NAME"
}

ensure_in_search_list() {
  if security list-keychains -d user | grep -q "ds-codex-ssh.keychain-db"; then
    return
  fi
  local existing=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    line="${line%\"}"
    line="${line#\"}"
    [[ -n "$line" ]] && existing+=("$line")
  done < <(security list-keychains -d user)
  security list-keychains -d user -s "${existing[@]}" "$KEYCHAIN"
}

if identity_ok; then
  security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" 2>/dev/null || true
  ensure_in_search_list
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat > ext.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = DS Codex SSH Signing
[v3]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -config ext.cnf 2>/dev/null
openssl pkcs12 -export -out cert.p12 -inkey key.pem -in cert.pem -passout pass:"$KEYCHAIN_PASS" -name "$IDENTITY_NAME"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security import cert.p12 -k "$KEYCHAIN" -P "$KEYCHAIN_PASS" -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null
ensure_in_search_list
security add-trusted-cert -p codeSign -k "$KEYCHAIN" cert.pem
echo "signing identity ready: $IDENTITY_NAME"
