# Test Vectors

This directory contains deterministic protocol and certificate vectors used by
the conformance harnesses.

## Key Files

- `vectors.json` - protocol-level vectors such as identity derivation and
  envelope validation
- `malformed-vectors.json` - malformed certificate catalog
- `cert-valid.der` / `cert-valid.pem` - reference valid certificate
- `generate-vectors.sh` - deterministic valid-certificate generator
- `generate-malformed.py` - malformed-certificate generator

## Notes

- Generated vector artifacts here support cross-implementation verification.
- Local tooling under `.venv/` is development-only and should not be treated as
  project documentation or wiki input.
