# Test Vectors

This directory contains cryptographic test vectors and certificates for cross-implementation conformance testing.

- `vectors.json`: Machine-readable JSON containing protocol-level test vectors (identity derivation, clipboard hashes, envelope validation, and raw DER encoding of the custom extension).
- `ec_p256_key.pem`: A reproducible ECDSA P-256 private key used for generating the test certificates.
- `openssl-ext.cnf` & `generate-vectors.sh`: OpenSSL configuration and script to deterministically generate a golden valid certificate.
- `cert-valid.der` / `cert-valid.pem`: The golden reference valid certificate.
- `malformed-vectors.json`: Catalog of malformed certificates for transport security failure testing.
- `generate-malformed.py`: Python script that generates the malformed variants from the golden `cert-valid.der`.
- `malformed-*.der`: The generated malformed certificate vectors.
