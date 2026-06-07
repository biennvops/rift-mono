#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

# Test key from protocol.md section 15.1
# d75a980182b10ab7d54bfed3c964073a0ee172f3daa3f4a18446b0b8d183f8e3

# Generate deterministic cert
openssl req -new -x509 \
  -key ec_p256_key.pem \
  -config openssl-ext.cnf \
  -days 3650 \
  -set_serial 0x01 \
  -out cert-valid.pem \
  -not_before 20200101000000Z \
  -not_after 20300101000000Z

# Convert to DER
openssl x509 -in cert-valid.pem -outform DER -out cert-valid.der

# Dump to verify
openssl x509 -in cert-valid.pem -noout -text > cert-valid.txt

echo "Generated cert-valid.pem, cert-valid.der, and cert-valid.txt"
