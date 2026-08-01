#!/usr/bin/env bash
set -euo pipefail

identity_name="Rift Development Code Signing"
keychain="${RIFT_DEV_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
openssl_bin="${OPENSSL:-/usr/bin/openssl}"
security_bin="/usr/bin/security"

if [[ ! -x "$openssl_bin" ]]; then
  echo "ERROR: OpenSSL was not found at '$openssl_bin'." >&2
  exit 1
fi
if [[ ! -x "$security_bin" ]]; then
  echo "ERROR: macOS security tool was not found." >&2
  exit 1
fi
if [[ ! -f "$keychain" ]]; then
  echo "ERROR: keychain does not exist: $keychain" >&2
  exit 1
fi

if "$security_bin" find-identity -v -p codesigning "$keychain" 2>/dev/null | grep -Fq "\"$identity_name\""; then
  echo "Signing identity already exists: $identity_name"
  "$security_bin" find-certificate -a -c "$identity_name" -Z "$keychain" 2>/dev/null | grep -E 'SHA-256 hash|SHA-1 hash|common name' || true
  echo
  echo "Use: RIFT_CODESIGN_IDENTITY='$identity_name'"
  exit 0
fi

if "$security_bin" find-certificate -a -c "$identity_name" "$keychain" >/dev/null 2>&1; then
  echo "ERROR: a partial or untrusted '$identity_name' certificate already exists." >&2
  echo "Remove that certificate in Keychain Access, then rerun this script." >&2
  exit 1
fi

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rift-dev-signing.XXXXXX")"
chmod 700 "$temp_dir"
trap 'rm -rf "$temp_dir"' EXIT

config="$temp_dir/openssl.cnf"
key="$temp_dir/rift-development.key.pem"
certificate="$temp_dir/rift-development.cer.pem"

cat > "$config" <<'EOF'
[req]
distinguished_name = subject
x509_extensions = codesigning
prompt = no

[subject]
CN = Rift Development Code Signing
O = Rift Development

[codesigning]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

"$openssl_bin" genrsa -out "$key" 2048 >/dev/null 2>&1
"$openssl_bin" req -new -x509 \
  -days 3650 \
  -config "$config" \
  -key "$key" \
  -out "$certificate" \
  >/dev/null 2>&1

"$security_bin" import "$key" \
  -k "$keychain" \
  -f openssl \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  >/dev/null

echo "macOS may request Keychain authorization to trust the development certificate."
"$security_bin" add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$keychain" \
  "$certificate" \
  >/dev/null

if ! "$security_bin" find-identity -v -p codesigning "$keychain" 2>/dev/null | grep -Fq "\"$identity_name\""; then
  echo "ERROR: certificate import completed but codesign does not recognize '$identity_name'." >&2
  exit 1
fi

echo "Created signing identity: $identity_name"
"$security_bin" find-certificate -a -c "$identity_name" -Z "$keychain" 2>/dev/null | grep -E 'SHA-256 hash|SHA-1 hash|common name' || true
echo
echo "Use: RIFT_CODESIGN_IDENTITY='$identity_name'"
echo "This identity is local-development-only and must not be used for release signing."
