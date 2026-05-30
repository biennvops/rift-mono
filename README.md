# Rift

Rift is a security-first cross-platform device continuity platform.

This repository contains the protocol specification, daemon implementations, Flutter app, and conformance/interop tests. The protocol specification is the source of truth for compatible implementations.

## Repository Layout

- `spec/` - language-independent Rift protocol specification and supporting materials.
- `daemon-cs/` - Windows daemon implementation in C#/.NET.
- `daemon-dart/` - Android daemon implementation in Dart.
- `app-flutter/` - Flutter app for Android and Windows.
- `tests-conformance/` - tests for implementation conformance to the written protocol.
- `tests-interop/` - cross-implementation interoperability tests.

## Protocol Specification

Start with `spec/doc/protocol.md`.

Architecture decisions live in `spec/decisions/`.

Local reference documents may be placed in `spec/references/`; this directory is intentionally not committed.

## Status

- **Tuần 1 & 2:** Khởi tạo thành công kiến trúc hạ tầng và các module giao tiếp gốc cho nhánh `daemon-dart`. Đã triển khai xong thuật toán sinh chứng chỉ X.509 (mTLS) tuân thủ đặc tả giao thức (ECDSA P-256).
- **Trạng thái hiện tại:** Đang phát triển các cơ chế giải mã (Parser) và khám phá thiết bị (mDNS).
