  # Rift Workspace Setup Plan

  ## Summary

  Set up a monorepo scaffold for Rift with protocol-first organization. The
  initial pass will create the workspace structure, placeholder spec/ADR
  files, .gitignore, and a short README.md. No protocol content, cryptographic
  test vectors, OIDs, ASN.1 modules, or implementation code will be generated
  yet.

  Because your prompt explicitly says not to run commands until approval, the
  tool availability report will be produced during the execution step after you
  approve. It will use only non-destructive version/location checks.

  ## Proposed Directory Tree

  Decision: use spec/doc/protocol.md as the main protocol document path, keeping
  generated/supporting spec assets separate from the prose spec.

  Rift/
  ├── README.md
  ├── .gitignore
  ├── spec/
  │   ├── doc/
  │   │   └── protocol.md
  │   ├── asn1/
  │   │   └── README.md
  │   ├── vectors/
  │   │   └── README.md
  │   ├── examples/
  │   │   └── README.md
  │   ├── decisions/
  │   │   ├── 0001-custom-extension-oid.md
  │   │   ├── 0002-tls-version-policy.md
  │   │   ├── 0003-protocol-versioning.md
  │   │   ├── 0004-intent-naming.md
  │   │   ├── 0005-clipboard-offer-hash-purpose.md
  │   │   ├── 0006-pairing-flow-transport.md
  │   │   ├── 0007-clock-skew-handling.md
  │   │   ├── 0008-device-fingerprint-canonicalization.md
  │   │   ├── 0009-mdns-service-identity-disclosure.md
  │   │   ├── 0010-json-rpc-error-model.md
  │   │   └── README.md
  │   └── references/
  │       └── README.md
  ├── daemon-cs/
  │   └── README.md
  ├── daemon-dart/
  │   └── README.md
  ├── app-flutter/
  │   └── README.md
  ├── tests-conformance/
  │   └── README.md
  └── tests-interop/
      └── README.md

  Decision: spec/references/ will be gitignored, but a tracked spec/references/
  README.md will document what to download and why.

  Decision: placeholder files will contain only short headers and purpose
  statements, not normative protocol content.

  ## Proposed spec/doc/protocol.md Table of Contents

  Decision: keep your requested section order exactly.

  # Rift Protocol Specification

  ## 1. Introduction and Scope

  ## 2. Terminology and Conventions

  ## 3. Cryptographic Primitives
  ### 3.1 Ed25519 Device Identity
  ### 3.2 ECDSA P-256 TLS Certificates
  ### 3.3 Custom X.509 Extension for Ed25519 Public Key
  ### 3.4 Fingerprint Derivation

  ## 4. Device Discovery: mDNS-SD

  ## 5. Transport Security
  ### 5.1 Mutual TLS 1.3
  ### 5.2 Post-Handshake Ed25519 Verification

  ## 6. Trust State Machine
  ### 6.1 States
  ### 6.2 Pairing
  ### 6.3 Revocation

  ## 7. Capability Negotiation

  ## 8. Intent Lifecycle
  <!-- Open decision: consider renaming "Intent" to avoid collision with
android.content.Intent. -->

  ## 9. Clipboard Offer/Fetch

  ## 10. Presence

  ## 11. Security Event Log Schema

  ## 12. Protocol Versioning and Compatibility

  ## 13. Test Vectors

  ## 14. Security Considerations

  ## Appendix A. ASN.1 Module

  ## Appendix B. Example Certificates

  ## Appendix C. Example Message Flows

  Decision: use numbered sections in protocol.md to make cross-references stable
  during implementation and review.

  ## Tool Availability Checks

  After approval, run non-destructive checks in parallel where possible. No
  installs will be performed.

  Commands to check:

  git --version
  openssl version
  xxd -h
  python3 --version
  dotnet --version
  dart --version
  flutter --version
  command -v markdownlint
  command -v markdownlint-cli2
  command -v mdbook
  command -v mermaid
  command -v mmdc
  command -v pandoc

  Tool report format:

  Tool              Status        Version / Notes
  git               installed     ...
  openssl           installed     ... verify 3.x
  xxd               installed     ...
  python3           installed     ...
  dotnet            installed     ...
  dart              installed     ...
  flutter           installed     ...
  Markdown tooling  installed     markdownlint/pandoc/etc if found
  Mermaid tooling   installed     mmdc/mermaid if found

  Install recommendations if missing or outdated:

  git: install via Xcode Command Line Tools or Homebrew.
  openssl 3.x: install via Homebrew package openssl@3; ensure PATH points to
OpenSSL 3 when needed.
  xxd: usually provided by Vim/macOS tooling; install Vim if absent.
  python3: install via python.org, pyenv, or Homebrew.
  dotnet: install current .NET SDK from Microsoft.
  dart/flutter: install Flutter SDK; Dart is bundled with Flutter for app work.
  markdownlint: install markdownlint-cli2 via npm or use editor integration.
  Mermaid CLI: install @mermaid-js/mermaid-cli via npm if diagram rendering is
needed.
  pandoc: optional, install via Homebrew if PDF/HTML export is desired.

  Decision: report exact versions only after running commands post-approval.

  ## Reference Documents

  Decision: store local reference copies in spec/references/, but keep the
  directory ignored by git to avoid committing downloaded standards, third-party
  docs, or CVE patch material.

  Tracked file:

  spec/references/README.md

  Reference list to document there:

  RFC 5280 - Internet X.509 Public Key Infrastructure Certificate and CRL Profile
  RFC 8032 - Edwards-Curve Digital Signature Algorithm, including Ed25519
  RFC 8446 - The Transport Layer Security Protocol Version 1.3
  RFC 6762 - Multicast DNS
  RFC 6763 - DNS-Based Service Discovery
  JSON-RPC 2.0 Specification
  KDE Connect protocol documentation
  KDE Connect fix commit for CVE-2025-66270
  KDE Connect fix commit for CVE-2025-32900
  KDE Connect fix commit for CVE-2025-32898

  Suggested local naming convention:

  spec/references/rfc5280.txt
  spec/references/rfc8032.txt
  spec/references/rfc8446.txt
  spec/references/rfc6762.txt
  spec/references/rfc6763.txt
  spec/references/json-rpc-2.0.md
  spec/references/kde-connect-protocol.md
  spec/references/kde-connect-cve-2025-66270.patch
  spec/references/kde-connect-cve-2025-32900.patch
  spec/references/kde-connect-cve-2025-32898.patch

  Decision: do not download these during setup unless separately approved later.

  ## Initial ADR List

  Each ADR will use a minimal template:

  # ADR NNNN: Title

  ## Status

  Proposed

  ## Context

  ## Decision

  ## Consequences

  Required ADRs:

  0001-custom-extension-oid.md
  Decision to make later: which OID identifies the Ed25519 public key X.509
extension.

  0002-tls-version-policy.md
  Decision to make later: TLS 1.3 only vs TLS 1.3 preferred with TLS 1.2 fallback.

  0003-protocol-versioning.md
  Decision to make later: protocol version shape, compatibility rules, and
negotiation behavior.

  0004-intent-naming.md
  Decision to make later: keep "Intent" or rename to avoid Android collision.

  0005-clipboard-offer-hash-purpose.md
  Decision to make later: exact security property of clipboard content hashes.

  0006-pairing-flow-transport.md
  Decision to make later: whether pairing occurs over mutual TLS, provisional TLS,
or a separate channel.

  0007-clock-skew-handling.md
  Decision to make later: relative TTLs vs absolute timestamps and clock skew
policy.

  Additional ADRs I recommend:

  0008-device-fingerprint-canonicalization.md
  Covers exactly what bytes are hashed/encoded for device fingerprints.

  0009-mdns-service-identity-disclosure.md
  Covers what discovery records may reveal before trust is established.

  0010-json-rpc-error-model.md
  Covers transport-agnostic JSON-RPC error codes, protocol errors, and daemon/app
boundary behavior.

  ## Proposed .gitignore

  Decision: include broad .NET, Dart/Flutter, editor, OS, build output, local
  env, logs, and ignored references.

  # OS files
  .DS_Store
  Thumbs.db

  # Editors and IDEs
  .vscode/
  .idea/
  *.swp
  *.swo
  *~

  # Local environment
  .env
  .env.*
  !.env.example

  # Logs
  *.log
  logs/

  # .NET
  bin/
  obj/
  .vs/
  *.user
  *.suo
  *.userosscache
  *.sln.docstates
  TestResults/
  coverage/
  *.nupkg

  # Dart and Flutter
  .dart_tool/
  .packages
  .pub-cache/
  .pub/
  build/
  .flutter-plugins
  .flutter-plugins-dependencies
  .generated_plugin_registrant.dart

  # Flutter platform/build artifacts
  android/.gradle/
  android/local.properties
  android/**/build/
  ios/Pods/
  ios/.symlinks/
  ios/Flutter/Flutter.framework
  ios/Flutter/Flutter.podspec
  macos/Flutter/ephemeral/
  linux/flutter/ephemeral/
  windows/flutter/ephemeral/

  # Test and coverage output
  coverage/
  lcov.info

  # Spec local references
  spec/references/*
  !spec/references/README.md

  # Temporary files
  tmp/
  temp/
  .cache/

  ## Proposed README.md Outline

  Decision: keep the root README short and navigational, not a full design
  document.

  # Rift

  Rift is a security-first cross-platform device continuity platform.

  This repository contains the protocol specification, daemon implementations,
Flutter app, and conformance/interop tests. The protocol specification is the
source of truth for compatible implementations.

  ## Repository Layout

  - `spec/` - language-independent Rift protocol specification and supporting
materials.
  - `daemon-cs/` - Windows daemon implementation in C#/.NET.
  - `daemon-dart/` - Android daemon implementation in Dart.
  - `app-flutter/` - Flutter app for Android and Windows.
  - `tests-conformance/` - tests for implementation conformance to the written
protocol.
  - `tests-interop/` - cross-implementation interoperability tests.

  ## Protocol Specification

  Start with `spec/doc/protocol.md`.

  Architecture decisions live in `spec/decisions/`.

  Local reference documents may be placed in `spec/references/`; this directory is
intentionally not committed.

  ## Status

  Initial workspace scaffold.

  ## Execution Steps After Approval

  1. Check tool availability using non-destructive version/location commands and
     report results.
  2. Initialize git only if the directory is not already a git repository.
  3. Create the proposed directories.
  4. Create placeholder README.md files and spec/doc/protocol.md with the table
     of contents only.
  5. Create ADR files with the minimal ADR template only.
  6. Create .gitignore.
  7. Report created files and tool availability.

  ## Open Questions and Assumptions

  Assumptions:

  The repo root is /Users/user/Developer/Rift.
  The primary spec file should be spec/doc/protocol.md.
  ADR files should live in spec/decisions/.
  Reference documents should not be committed.
  No protocol content, OIDs, ASN.1 structures, certificates, or test vectors
should be generated in this setup pass.

  Open questions:

  Should the main spec path be spec/doc/protocol.md, or would you prefer spec/
protocol.md?

  Should ADRs use "Proposed" as the initial status, or a different status such as
"Draft"?

  Should placeholder README files be one-line purpose markers, or should they
include slightly more detailed guidance for future contributors?

  Should git initialization happen automatically if this directory is not already
a repository, or should setup only create files and leave git untouched?
