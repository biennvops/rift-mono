# Rift Android Daemon (Dart) - Usage Guide & Architecture

This is the core background module (daemon) on the Android OS for the Rift project, developed using the Dart language. The mission of this module is to securely communicate with the Windows Daemon (via mTLS) and provide services to the Flutter UI (via JSON-RPC).

---

## 1. Directory Structure

- `lib/src/interfaces/`: Contains 5 core Interfaces (`IdentityManager`, `TrustStore`, `Transport`, `DiscoveryService`, `ClipboardService`). All business operations must go through these interfaces.
- `lib/src/crypto/`: Contains extremely important cryptographic logic, notably `cert_builder.dart` for automatically wrapping the Ed25519 key into an X.509 certificate using the *Double OCTET STRING* technique.
- `test/`: Contains security test scenarios (Fail-Closed).
- `demo_cert.dart`: A sample script to test generating a valid `demo.pem` certificate file to disk.

---

## 2. Usage Guide & Basic Commands

### 2.1. Install Dependencies
Before working, ensure you have downloaded enough libraries (`pointycastle`, `asn1lib`):
```bash
dart pub get
```

### 2.2. Code Quality Check (Linter)
All code pushed to the branch must not have warnings. The Linter system is strictly configured in `analysis_options.yaml`.
```bash
dart analyze
```
> **Note:** Must output `No issues found!` to create a Pull Request.

### 2.3. Run Security Unit Tests
Run all test scenarios to verify that the encryption module generates the correct ASN.1 byte array.
```bash
dart test
```
> **Case of Test Failure (Fail-Closed):**
> If the system prints `Expected: <...>` but `Actual: <...>`, accompanied by a red message `Some tests failed. Exit code: 1`. 
> - **Conclusion:** It proves that the ASN.1 byte array of the certificate has been manipulated or the structure does not match the X.509 specification. The **Fail-Closed** mechanism has been triggered, shutting down the execution flow immediately.
> - **Consequence:** Your Pull Request will be completely blocked by CI/CD, absolutely not allowed to Merge into the main branch to protect the system from Parser vulnerabilities.

### 2.4. Run Demo Script (Generate Certificate)
To test the self-signed certificate generation feature of Week 2, you can run the command:
```bash
dart run demo_cert.dart
```
This command will create a `demo.pem` file right in the root directory. You can use `openssl x509 -in demo.pem -text -noout` to manually check the internal structure.

---

## 3. Compliance Level with System Specification (Protocol & IPC)
- **With `protocol.md`:** Strictly adhered 100% to cryptographic requirements (ECDSA + Ed25519 X.509 Extension) via `cert_builder.dart` in Week 2, using the `pointycastle` and `asn1lib` platforms prepared in Week 1.
- **With `ipc.md`:** Built 5 Interfaces (Abstract) in Week 2 to create an Abstraction Layer, paving the way for JSON-RPC 2.0 connections from Flutter UI straight into business modules in the coming weeks. Not hard-coded to any transport technology.
