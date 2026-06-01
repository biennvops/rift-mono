# Rift Android Daemon (Dart) - Usage Guide & Summary

This is the core background module (daemon) on the Android OS for the Rift project, developed using the Dart language.

---

## 1. Usage Guide & Basic Commands

Below are the basic commands to work with the codebase of the `daemon-dart` directory (Week 1):

### Run Unit Tests (Environment Check)
Ensure the Dart system has the packages installed correctly and the runtime environment is smooth.
```bash
dart test
```

### Source Code Analysis (Dart Linter)
Check if the code violates any formatting rules or naming conventions of Dart.
```bash
dart analyze
```
- **Success (`No issues found!`):** Code is 100% clean, meeting standards.
- **Failure:** Reports Warning errors. Strictly do not Push code to Git if this command does not return green.

---

## 2. Conclusion: Week 1 Deliverables (100% Completed)

In Week 1 of the project, Kiet (Android Daemon Lead) successfully completed the "Infrastructure Initialization" (`[daemon-dart][infra]`) objective assigned in `finaltask.md`:

1. **Core Infrastructure Setup:**
   - Successfully initialized the standard Dart project (`daemon-dart`).
   - Successfully integrated core cryptography libraries: `pointycastle` (for ECDSA P-256), `asn1lib` (for handling ASN.1 byte arrays), and `basic_utils`.

2. **Error Cleanup & Clean Code:**
   - Completely resolved Dart Linter warnings.
   - Codebase is clean and ready for building the Interface architecture and X.509 cryptography in Week 2.
