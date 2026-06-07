import json
import os
from asn1crypto import x509, core

def load_cert(path):
    with open(path, 'rb') as f:
        return x509.Certificate.load(f.read())

def save_cert(cert_obj, path):
    with open(path, 'wb') as f:
        f.write(cert_obj.dump())

def find_rift_ext_index(extensions):
    for i, ext in enumerate(extensions):
        if ext['extn_id'].native == '2.25.293029629918709742181702189012786017422':
            return i
    return -1

def generate_malformed(base_der_path):
    os.makedirs('spec/vectors', exist_ok=True)
    
    # 1. Ext absent
    cert = load_cert(base_der_path)
    tbs = cert['tbs_certificate']
    exts = tbs['extensions']
    idx = find_rift_ext_index(exts)
    del exts[idx]
    save_cert(cert, 'spec/vectors/malformed-01-ext-absent.der')
    
    # 2. Ext duplicated
    cert = load_cert(base_der_path)
    tbs = cert['tbs_certificate']
    exts = tbs['extensions']
    idx = find_rift_ext_index(exts)
    exts.append(exts[idx])
    save_cert(cert, 'spec/vectors/malformed-02-ext-duplicated.der')
    
    # 3. Ext critical
    cert = load_cert(base_der_path)
    tbs = cert['tbs_certificate']
    exts = tbs['extensions']
    idx = find_rift_ext_index(exts)
    exts[idx]['critical'] = True
    save_cert(cert, 'spec/vectors/malformed-03-ext-critical.der')
    
    # 4. Wrong OID
    cert = load_cert(base_der_path)
    tbs = cert['tbs_certificate']
    exts = tbs['extensions']
    idx = find_rift_ext_index(exts)
    exts[idx]['extn_id'] = x509.ExtensionId('1.2.3.4')
    save_cert(cert, 'spec/vectors/malformed-04-wrong-oid.der')
    
    # 5. Key too short (31 bytes)
    cert = load_cert(base_der_path)
    tbs = cert['tbs_certificate']
    exts = tbs['extensions']
    idx = find_rift_ext_index(exts)
    exts[idx]['extn_value'] = core.ParsableOctetString(core.OctetString(b'\x00' * 31).dump())
    save_cert(cert, 'spec/vectors/malformed-05-key-too-short.der')
    
    # 6. Key too long (33 bytes)
    cert = load_cert(base_der_path)
    tbs = cert['tbs_certificate']
    exts = tbs['extensions']
    idx = find_rift_ext_index(exts)
    exts[idx]['extn_value'] = core.ParsableOctetString(core.OctetString(b'\x00' * 33).dump())
    save_cert(cert, 'spec/vectors/malformed-06-key-too-long.der')
    
    # 7. Wrong tag
    cert = load_cert(base_der_path)
    tbs = cert['tbs_certificate']
    exts = tbs['extensions']
    idx = find_rift_ext_index(exts)
    # Use BIT STRING (03) instead of OCTET STRING (04)
    # Create BitString correctly: tuple of 1s and 0s
    bs = core.BitString((0,) * (32 * 8))
    exts[idx]['extn_value'] = core.ParsableOctetString(bs.dump())
    save_cert(cert, 'spec/vectors/malformed-07-wrong-tag.der')
    
    # Generate 8 and 9 using raw byte manipulation
    with open(base_der_path, 'rb') as f:
        der = bytearray(f.read())
    
    pattern = bytes.fromhex('04220420d75a980182b10ab7d54bfed3c964073a0ee172f3daa3f4a18446b0b8d183f8e3')
    idx = der.find(pattern)
    
    if idx != -1:
        # 8. Truncated DER (cut inside the extn_value)
        trunc_der = der[:idx + 10]
        with open('spec/vectors/malformed-08-truncated-der.der', 'wb') as f:
            f.write(trunc_der)
            
        # 9. Oversized extnValue (length field is larger than actual bytes)
        # Modify the 04 22 length byte to 04 40
        oversized_der = bytearray(der)
        oversized_der[idx + 1] = 0x40
        with open('spec/vectors/malformed-09-oversized-extnvalue.der', 'wb') as f:
            f.write(oversized_der)

    # Output JSON catalog
    catalog = {
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
    with open('spec/vectors/malformed-vectors.json', 'w') as f:
        json.dump(catalog, f, indent=2)

if __name__ == '__main__':
    generate_malformed('spec/vectors/cert-valid.der')
