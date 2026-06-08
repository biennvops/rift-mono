#!/usr/bin/env python3
import json
import os
import sys
from asn1crypto import x509, core

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RIFT_OID = '2.25.293029629918709742181702189012786017422'
EXTN_VALUE_PATTERN = bytes.fromhex(
    '04220420d75a980182b10ab7d54bfed3c964073a'
    '0ee172f3daa3f4a18446b0b8d183f8e3'
)

def load_cert(path):
    with open(path, 'rb') as f:
        return x509.Certificate.load(f.read())

def save_cert(cert_obj, path):
    with open(path, 'wb') as f:
        f.write(cert_obj.dump())

def find_rift_ext_index(extensions):
    for i, ext in enumerate(extensions):
        if ext['extn_id'].native == RIFT_OID:
            return i
    return -1

def out_path(filename):
    return os.path.join(SCRIPT_DIR, filename)

def generate_malformed(base_der_path):
    # 1. Extension absent
    cert = load_cert(base_der_path)
    exts = cert['tbs_certificate']['extensions']
    idx = find_rift_ext_index(exts)
    del exts[idx]
    save_cert(cert, out_path('malformed-01-ext-absent.der'))

    # 2. Extension duplicated
    cert = load_cert(base_der_path)
    exts = cert['tbs_certificate']['extensions']
    idx = find_rift_ext_index(exts)
    exts.append(exts[idx])
    save_cert(cert, out_path('malformed-02-ext-duplicated.der'))

    # 3. Extension marked critical
    cert = load_cert(base_der_path)
    exts = cert['tbs_certificate']['extensions']
    idx = find_rift_ext_index(exts)
    exts[idx]['critical'] = True
    save_cert(cert, out_path('malformed-03-ext-critical.der'))

    # 4. Wrong OID
    cert = load_cert(base_der_path)
    exts = cert['tbs_certificate']['extensions']
    idx = find_rift_ext_index(exts)
    exts[idx]['extn_id'] = x509.ExtensionId('1.2.3.4')
    save_cert(cert, out_path('malformed-04-wrong-oid.der'))

    # 5. Key too short (31 bytes)
    cert = load_cert(base_der_path)
    exts = cert['tbs_certificate']['extensions']
    idx = find_rift_ext_index(exts)
    exts[idx]['extn_value'] = core.ParsableOctetString(core.OctetString(b'\x00' * 31).dump())
    save_cert(cert, out_path('malformed-05-key-too-short.der'))

    # 6. Key too long (33 bytes)
    cert = load_cert(base_der_path)
    exts = cert['tbs_certificate']['extensions']
    idx = find_rift_ext_index(exts)
    exts[idx]['extn_value'] = core.ParsableOctetString(core.OctetString(b'\x00' * 33).dump())
    save_cert(cert, out_path('malformed-06-key-too-long.der'))

    # 7. Wrong tag (BIT STRING 0x03 instead of OCTET STRING 0x04)
    cert = load_cert(base_der_path)
    exts = cert['tbs_certificate']['extensions']
    idx = find_rift_ext_index(exts)
    bs = core.BitString((0,) * (32 * 8))
    exts[idx]['extn_value'] = core.ParsableOctetString(bs.dump())
    save_cert(cert, out_path('malformed-07-wrong-tag.der'))

    # Cases 8 and 9 require raw byte manipulation of the golden cert DER.
    with open(base_der_path, 'rb') as f:
        der = bytearray(f.read())

    idx = der.find(EXTN_VALUE_PATTERN)
    if idx == -1:
        print(
            'ERROR: could not find outer extnValue pattern in golden cert. '
            'Cases 8-9 will not be generated. '
            'Regenerate cert-valid.der with the RFC 8032 test key.',
            file=sys.stderr,
        )
        sys.exit(1)

    # 8. Truncated DER (cut inside the extnValue)
    trunc_der = der[:idx + 10]
    with open(out_path('malformed-08-truncated-der.der'), 'wb') as f:
        f.write(trunc_der)

    # 9. Oversized extnValue (outer length 0x40 instead of 0x22)
    oversized_der = bytearray(der)
    oversized_der[idx + 1] = 0x40
    with open(out_path('malformed-09-oversized-extnvalue.der'), 'wb') as f:
        f.write(oversized_der)

    # Output JSON catalog
    catalog = {
        "version": "0.1-draft",
        "note": "Class 10 (valid structure, untrusted key) is a trust-layer check, not a DER parsing defect. It is intentionally excluded from this set.",
        "classes": [
            {
                "id": 1,
                "file": "malformed-01-ext-absent.der",
                "defect": "Extension removed entirely",
                "expectedFailure": "AuthenticationFailed",
                "expectedEvent": "certificate.malformed"
            },
            {
                "id": 2,
                "file": "malformed-02-ext-duplicated.der",
                "defect": "Rift OID extension appears twice",
                "expectedFailure": "AuthenticationFailed",
                "expectedEvent": "certificate.malformed"
            },
            {
                "id": 3,
                "file": "malformed-03-ext-critical.der",
                "defect": "Extension marked critical",
                "expectedFailure": "AuthenticationFailed",
                "expectedEvent": "certificate.malformed"
            },
            {
                "id": 4,
                "file": "malformed-04-wrong-oid.der",
                "defect": "Different OID used",
                "expectedFailure": "AuthenticationFailed",
                "expectedEvent": "certificate.malformed"
            },
            {
                "id": 5,
                "file": "malformed-05-key-too-short.der",
                "defect": "Inner OCTET STRING is 31 bytes",
                "expectedFailure": "AuthenticationFailed",
                "expectedEvent": "certificate.malformed"
            },
            {
                "id": 6,
                "file": "malformed-06-key-too-long.der",
                "defect": "Inner OCTET STRING is 33 bytes",
                "expectedFailure": "AuthenticationFailed",
                "expectedEvent": "certificate.malformed"
            },
            {
                "id": 7,
                "file": "malformed-07-wrong-tag.der",
                "defect": "Inner tag 03 (BIT STRING) instead of 04",
                "expectedFailure": "AuthenticationFailed",
                "expectedEvent": "certificate.malformed"
            },
            {
                "id": 8,
                "file": "malformed-08-truncated-der.der",
                "defect": "Tag+length present but value bytes cut short",
                "expectedFailure": "AuthenticationFailed",
                "expectedEvent": "certificate.malformed"
            },
            {
                "id": 9,
                "file": "malformed-09-oversized-extnvalue.der",
                "defect": "Length field claims more bytes than exist",
                "expectedFailure": "AuthenticationFailed",
                "expectedEvent": "certificate.malformed"
            }
        ]
    }
    with open(out_path('malformed-vectors.json'), 'w') as f:
        json.dump(catalog, f, indent=2)
        f.write('\n')

    print(f'Generated 9 malformed vectors and malformed-vectors.json in {SCRIPT_DIR}')

if __name__ == '__main__':
    generate_malformed(os.path.join(SCRIPT_DIR, 'cert-valid.der'))
