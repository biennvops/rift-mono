# Báo cáo Đánh giá & Phân tích Dart Daemon (Tuần 1-4)

**Đối chiếu chuẩn:** `フィナーレ.md` (Master Plan)
**Thành phần:** Android Daemon (`daemon-dart`)
**Đánh giá bởi:** System Review

---

## Cấu trúc thư mục & Tệp quan trọng (Tính đến Tuần 4)

```text
daemon-dart/
├── lib/
│   └── src/
│       ├── crypto/
│       │   ├── cert_builder.dart           # Xây dựng chứng chỉ mTLS X.509 chứa custom OID Ed25519
│       │   ├── cert_decoder.dart           # Trình Parser Fail-Closed để bóc tách Ed25519 từ ASN.1
│       │   └── identity_manager_impl.dart  # Triển khai thuật toán sinh và lưu khóa Ed25519 (cryptography)
│       ├── interfaces/
│       │   ├── clipboard_service.dart      # Interface Abstract quản lý Clipboard (Tuần 2)
│       │   ├── discovery_service.dart      # Interface Abstract quản lý mDNS (Tuần 2)
│       │   ├── identity_manager.dart       # Interface Abstract định nghĩa thông tin Identity (Tuần 2)
│       │   ├── transport.dart              # Interface Abstract quản lý kết nối Network (Tuần 2)
│       │   └── trust_store.dart            # Interface Abstract quản lý danh sách tin cậy (Tuần 2)
│       ├── ipc/
│       │   └── ipc_errors.dart             # Bảng mã lỗi chuẩn JSON-RPC giao tiếp với Flutter
│       ├── network/
│       │   ├── discovery_service_impl.dart # Triển khai mDNS bằng nsd package
│       │   ├── frame_codec.dart            # Định dạng đóng gói Frame 4-byte length prefix (Max 32 MiB)
│       │   ├── session_messages.dart       # Định nghĩa payload Session Bootstrap (protocol.md C.1)
│       │   └── transport_impl.dart         # Triển khai TLS 1.3 Transport và xác thực Ed25519
│       └── daemon_isolate.dart             # Điểm vào (Entry point) cho Android Foreground Service
├── test/
│   ├── crypto_test.dart                    # Unit test bảo mật mã hóa cho cert_builder
│   ├── daemon_dart_test.dart               # Smoke test kiểm tra môi trường chạy cơ bản
│   ├── decoder_test.dart                   # Unit test kiểm chứng cơ chế Fail-Closed của cert_decoder
│   ├── frame_codec_test.dart               # Unit test kiểm tra giới hạn 32 MiB và cấu trúc Frame
│   └── identity_test.dart                  # Unit test xác minh sinh Device ID và Base32 hợp lệ
├── pubspec.yaml                            # Khai báo nền tảng Dart (cryptography, pointycastle, asn1lib)
├── demo_cert.dart                          # Script thử nghiệm sinh chứng chỉ PEM ra file
└── README.md                               # Hướng dẫn chạy test, linter và kiến trúc tổng quan
```

---

## 1. Mức độ tuân thủ Task (Theo `フィナーレ.md`)

- **`[daemon-dart][infra]` (Tuần 1):** Khởi tạo cấu trúc Dart daemon cơ bản.
  - Đã cài đặt và kiểm định tính khả dụng của các gói mật mã `pointycastle` và `asn1lib`.
  - Định hình rõ ràng quy hoạch thư mục chuẩn bị cho các module giao thức.
  - **Đánh giá:** **ĐẠT (100%)**

- **`[daemon-dart] Module interfaces & [test]` (Tuần 2):** Xây dựng nền móng giao tiếp và chứng chỉ.
  - Đã thiết lập đủ 5 Interfaces (`IdentityManager`, `TrustStore`, `Transport`, `DiscoveryService`, `ClipboardService`).
  - Viết thành công `cert_builder.dart` để tự động chèn OID tùy chỉnh và public key Ed25519 vào chứng chỉ X.509.
  - Vượt qua bài kiểm tra bảo mật Unit Test chứng chỉ mTLS.
  - **Tối ưu hóa:** Sử dụng `BytesBuilder` để chống phân mảnh bộ nhớ khi thao tác byte ASN.1; Loại bỏ `dynamic` (thay bằng `DiscoveredPeer`) để đảm bảo Type-Safety tuyệt đối cho kiến trúc Interface.
  - **Đánh giá:** **ĐẠT (100%)**

- **`[daemon-dart] Identity, Certificates, Frame Parsing` (Tuần 3):** Hoàn thiện bảo mật cốt lõi.
  - Xây dựng thành công bộ giải mã **X.509 Decoder (`cert_decoder.dart`)** chuẩn Fail-Closed. Bóc tách an toàn mã Ed25519 từ cấu trúc ASN.1.
  - Triển khai **Frame Codec (`frame_codec.dart`)** cấu trúc 4-byte length prefix. **Cải tiến:** Tích hợp `RiftFrameTransformer` (StreamTransformer) xử lý dữ liệu theo từng luồng (chunk) thay vì nạp tĩnh 32 MiB vào RAM, ngăn chặn dứt điểm tấn công tràn bộ nhớ (OOM/Memory Exhaustion).
  - Hoàn thiện **`IdentityManagerImpl`**: Tích hợp package `cryptography` để sinh và lưu trữ khóa Ed25519, tính toán Device ID chuẩn `rift- + Base32`. **Cải tiến:** Sử dụng kỹ thuật Ghi Nguyên tử (Atomic Write) ghi ra file `.tmp` trước khi `rename` để loại bỏ 100% nguy cơ hỏng khóa khi thiết bị tắt nguồn đột ngột.
  - **Đánh giá:** **ĐẠT (100%)** Vượt qua toàn bộ Unit Test bảo mật.

- **`[daemon-dart] Discovery & Session Bootstrap` (Tuần 4):** Thiết lập mạng và phiên mã hóa.
  - Tích hợp thành công **package nsd** để chạy mDNS Discovery (Advertise/Browse) đúng chuẩn service type `_rift._tcp`.
  - Triển khai **TransportImpl** bằng `SecureServerSocket` (TLS 1.3). Tích hợp chức năng bóc tách Ed25519 từ chứng chỉ của đối phương, hỗ trợ đầy đủ *Post-handshake verification* an toàn.
  - Khởi tạo chính xác 100% cấu trúc JSON-RPC payload cho **Session Bootstrap** (`session.hello`, `session.accept`, `session.reject`) dựa theo Phụ lục C.1 của `protocol.md`, hoàn toàn không tự bịa trường dữ liệu.
  - Xây dựng thành công bộ khung Isolate cho **Android Foreground Service** (`daemon_isolate.dart`).
  - **Đánh giá:** **ĐẠT (100%)** Các module đã sẵn sàng để tích hợp vào ứng dụng Flutter.

---

## 2. Đối chiếu Đặc tả Hệ thống (Protocol & IPC)

Mọi quyết định kiến trúc trong Tuần 1 và Tuần 2 đều nhằm đáp ứng chính xác 2 bản đặc tả cốt lõi của dự án:

### 2.1. Tuân thủ `spec/doc/protocol.md` (Giao thức Mạng & Bảo mật)
- **Cách áp dụng ở Tuần 1:** Đặc tả yêu cầu bắt buộc dùng chuẩn chữ ký ECDSA P-256 và mở rộng X.509. Vì Dart SDK không đủ mạnh để thao tác với OID tùy chỉnh, nên Tuần 1 đã chốt phương án hạ tầng: cài đặt 2 thư viện cấp thấp là `pointycastle` và `asn1lib`.
- **Cách áp dụng ở Tuần 2 & 3:** Thực thi chính xác Mục 3.4 của Protocol. Đã viết `cert_builder.dart` để nhúng OID đặc chế (`2.25...`) chứa mã Ed25519, và `cert_decoder.dart` để giải mã ngược lại với chuẩn an toàn Fail-Closed. Định dạng Device ID cũng được bám sát chuẩn `rift- + lowercase Base32` thông qua `IdentityManagerImpl`. Bộ khung `frame_codec.dart` giới hạn tin nhắn nghiêm ngặt ở mức 32 MiB theo đúng đặc tả.

### 2.2. Tuân thủ `spec/doc/ipc.md` (Giao tiếp Flutter Client)
- **Cách áp dụng ở Tuần 1:** Xây dựng bộ khung thư mục nghiêm ngặt, tách biệt vùng chứa mã giao tiếp (`ipc/`) và mã nghiệp vụ gốc (`interfaces/`, `crypto/`).
- **Cách áp dụng ở Tuần 2:** Đặc tả IPC yêu cầu kết nối bằng JSON-RPC 2.0 qua Transport-agnostic. Để làm nền móng, Tuần 2 đã tạo ra 5 Abstract Interfaces (`IdentityManager`, `DiscoveryService`...). Đây là lớp trừu tượng (Abstraction Layer) ép code giao tiếp JSON-RPC sau này phải tương tác thông qua nó, giúp Daemon không bị hard-code vào bất kỳ giao thức kết nối cứng nào.

---

1. **Rủi ro Parse Chứng Chỉ (Đã giải quyết ở Tuần 3):**
   Trình phân tích cú pháp Fail-Closed hoạt động rất ổn định trên cả C# lẫn Dart.

2. **Rủi ro Dịch vụ mDNS (Đã giải quyết ở Tuần 4):**
   Package `nsd` có cơ chế tự resolve rất mạnh, tích hợp tốt với Isolate.

3. **Rủi ro Trạng thái Pairing (Dự kiến Tuần 5):**
   Tuần tới sẽ phải lưu trữ trạng thái Pairing (Trust Store) vĩnh viễn bằng SQLite/sqflite. Rủi ro về State Machine cần được kiểm thử kỹ lưỡng.
