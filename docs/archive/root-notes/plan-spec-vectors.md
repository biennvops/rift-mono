# Plan: Spec Document Work for Issues #5 and #9

## Context

- **Issue #5**: Authoritative test vectors via OpenSSL, Spec section 3 ASN.1 module, Conformance test runner harness
- **Issue #9**: Spec section 5 conformance test cases for failure paths (malformed extension, wrong OID, wrong key length), Spec section 13/15 test vectors updated

## Current State

| Path | Status |
|------|--------|
| `spec/doc/protocol.md` | Full v0.1-draft spec, sections 1–16 + appendices A/B/C |
| `spec/doc/ipc.md` | Full IPC API spec |
| `spec/asn1/` | Placeholder README only |
| `spec/vectors/` | Placeholder README only |
| `spec/examples/` | Placeholder README only |
| `tests-conformance/` | Placeholder README only |

**Existing spec coverage:**
- Section 3.5 defines the custom X.509 extension conceptually
- Section 15 has test vectors for identity derivation, DER encoding, clipboard hash, envelope validation
- Appendix A has a one-line ASN.1 type: `RiftEd25519PublicKey ::= OCTET STRING (SIZE(32))`
- Appendix B.3 has a malformed certificate rejection catalog (10 classes)

## Tooling Verified

- **OpenSSL 3.6.2** — supports `-not_before`/`-not_after` for deterministic dates, handles the long 2.25-arc OID natively via `ASN1:FORMAT:HEX,OCTETSTRING:...` arbitrary extension syntax
- **Python 3.14.5** — venv at `spec/vectors/.venv` with `pyasn1`, `asn1crypto`, `cryptography 48.0` installed
- **DER round-trip confirmed** — generated a test cert, extracted extension bytes, verified byte-identical match with protocol.md Section 15.2 (`303a0614698...`)

## Deliverables

Each deliverable gets its own branch and commit.

---

### D1: Formal ASN.1 Module

**Branch:** `spec/asn1-module`

**Files:**
- `spec/asn1/RiftExtension.asn1` — proper ASN.1 module with:
  - Module header (`RiftExtension DEFINITIONS`)
  - OID assignment: `id-rift-ed25519-identity OBJECT IDENTIFIER ::= { joint-iso-itu-t(2) uuid(25) 293029629918709742181702189012786017422 }`
  - Type: `RiftEd25519PublicKey ::= OCTET STRING (SIZE (32))`
  - IMPORTS from PKIX1Explicit88 for `Extension` type
- `spec/asn1/README.md` — updated from placeholder

---

### D2: OpenSSL Test Vector Generation

**Branch:** `spec/openssl-vectors`

**Files:**
- `spec/vectors/ec_p256_key.pem` — committed fixed ECDSA P-256 key for reproducibility
- `spec/vectors/openssl-ext.cnf` — OpenSSL config with the custom extension using `ASN1:FORMAT:HEX,OCTETSTRING:<RFC 8032 test key>`
- `spec/vectors/generate-vectors.sh` — reproducible script that:
  1. Reuses the committed key
  2. Generates self-signed cert with fixed serial (`0x01`), pinned dates (`20200101000000Z` to `20300101000000Z`)
  3. Outputs `cert-valid.pem` and `cert-valid.der`
  4. Runs verification (asn1parse, text dump, DER hex extraction)
- `spec/vectors/cert-valid.pem` / `cert-valid.der` — the golden reference certificate

---

### D3: Machine-Readable Test Vector JSON

**Branch:** `spec/vectors-json`

**Files:**
- `spec/vectors/vectors.json` — consolidates all Section 15 test vectors:
  - `identityDerivation`: Ed25519 pubkey → SHA-256 → Base32 → device ID → fingerprint
  - `extensionDer`: OID hex, inner extnValue, outer extnValue, complete SEQUENCE
  - `clipboardHash`: content → SHA-256 → Base64
  - `envelopeValidation`: valid and invalid envelope examples
- `spec/vectors/README.md` — updated from placeholder

---

### D4: Malformed Certificate Vectors

**Branch:** `spec/malformed-vectors`

**Files:**
- `spec/vectors/generate-malformed.py` — Python script using `cryptography`/`asn1crypto` that:
  1. Starts from the golden `cert-valid.der`
  2. Produces 9 malformed variants, each with exactly one defect

| # | File | Defect |
|---|------|--------|
| 1 | `malformed-01-ext-absent.der` | Extension removed entirely |
| 2 | `malformed-02-ext-duplicated.der` | Rift OID extension appears twice |
| 3 | `malformed-03-ext-critical.der` | Extension marked critical |
| 4 | `malformed-04-wrong-oid.der` | Different OID used |
| 5 | `malformed-05-key-too-short.der` | Inner OCTET STRING is 31 bytes |
| 6 | `malformed-06-key-too-long.der` | Inner OCTET STRING is 33 bytes |
| 7 | `malformed-07-wrong-tag.der` | Inner tag `03` (BIT STRING) instead of `04` |
| 8 | `malformed-08-truncated-der.der` | Tag+length present but value bytes cut short |
| 9 | `malformed-09-oversized-extnvalue.der` | Length field claims more bytes than exist |

- `spec/vectors/malformed-vectors.json` — catalog mapping each class to file, expected failure reason (`AuthenticationFailed`), expected event type (`certificate.malformed`)

---

### D5: Conformance Test Runner Harness

**Branch:** `spec/conformance-harness`

**Structure:**
```
tests-conformance/
├── README.md                    — describes harness, how to add a runner
├── schema.md                    — documents the JSON test-case schema
├── testcases/
│   ├── identity-derivation.json
│   ├── extension-der.json
│   ├── certificate-parsing.json — references cert-valid + malformed vectors
│   ├── clipboard-hash.json
│   ├── envelope-validation.json
│   └── manifest.json            — index of all test suites
└── runners/
    ├── dotnet/                  — skeleton C# runner for daemon-cs
    └── dart/                    — skeleton Dart runner for daemon-dart
```

Test case format follows Wycheproof-inspired pattern:
```json
{
  "id": "cert-malformed-01",
  "input": { "file": "../../spec/vectors/malformed-01-ext-absent.der" },
  "expected": { "result": "reject", "error": "AuthenticationFailed" }
}
```

Runners are thin skeletons — actual implementation is daemon team work.

---

### D6: Protocol Spec Updates

**Branch:** `spec/protocol-doc-updates`

**Edits to `spec/doc/protocol.md`:**

| Section | Change |
|---------|--------|
| 3.5 | Add reference to `spec/asn1/RiftExtension.asn1` as the formal ASN.1 module |
| 5 (intro) | Add paragraph: conformance test cases for transport security failure paths are defined in `spec/vectors/malformed-vectors.json` |
| 15 (intro) | Replace "full certificate bytes are future conformance material" with reference to generated vectors |
| 15.2 | Add note: authoritative certificate vector is `spec/vectors/cert-valid.der`, generated by `generate-vectors.sh` |
| New 15.5 | "Malformed Certificate Vectors" — table mapping B.3 classes 1–9 to vector files, expected failure reasons, expected event types |
| Appendix A | Expand with formal module reference |
| Appendix B | Add cross-reference to generated malformed certs |

---

## Execution Order

```
D1 (ASN.1 module)          — standalone, no dependencies
  ↓
D2 (OpenSSL golden cert)   — needs Ed25519 test key from Section 15.1
  ↓
D3 (vectors.json)          — codifies existing spec text, references D2 cert
  ↓
D4 (malformed vectors)     — depends on golden cert from D2
  ↓
D5 (conformance harness)   — depends on D3 and D4 for references
  ↓
D6 (spec updates)          — references all generated files
```

## Research Notes

Key findings from pre-implementation research:

- **OpenSSL long OID**: OpenSSL uses BIGNUM for OID arcs, so `2.25.293029629918709742181702189012786017422` works natively. Use arbitrary extension syntax: `2.25.<oid> = ASN1:FORMAT:HEX,OCTETSTRING:<hex>`
- **Deterministic certs**: Pin serial with `-set_serial`, dates with `-not_before`/`-not_after` (OpenSSL 3.2+), commit the key file. TBSCertificate is byte-stable; signature varies (no RFC 6979 in OpenSSL CLI for cert signing)
- **Malformed cert generation**: OpenSSL can't produce most malformations. Use Python `cryptography`/`asn1crypto` for raw DER manipulation — generate golden cert, then surgically corrupt bytes for each defect class
- **OID DER verified**: `06 14 69 83 b8 f3 ba 8c ba bf ca d1 cd 9a ab f7 88 88 95 fb e9 0e` — first byte `69` = 2×40+25=105, remaining 19 bytes are VLQ of the large arc. Matches spec exactly
- **Conformance harness pattern**: Wycheproof/NIST PKITS model — declarative JSON test cases with binary artifacts referenced by path, thin per-language runners. Keep test logic in JSON, runners minimal
