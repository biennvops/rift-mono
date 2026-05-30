# Báo cáo Đánh giá & Phân tích Dart Daemon (Tuần 1 & 2)

**Đối chiếu chuẩn:** `フィナーレ.md` (Master Plan)
**Thành phần:** Android Daemon (`daemon-dart`)
**Đánh giá bởi:** System Review

---

## Cấu trúc thư mục & Tệp quan trọng (Tính đến Tuần 2)

```text
daemon-dart/
├── lib/
│   └── src/
│       ├── crypto/            # Chứa logic sinh chứng chỉ X.509 (cert_builder.dart)
│       └── interfaces/        # Chứa 5 interface cốt lõi của Daemon (identity, transport...)
├── test/                      # Chứa file crypto_test.dart
├── pubspec.yaml               # Khai báo nền tảng Dart và các thư viện cốt lõi
├── demo_cert.dart             # Script chạy sinh thử chứng chỉ PEM
└── README.md                  # Hướng dẫn chạy test và Linter
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

---

## 2. Đối chiếu Đặc tả Hệ thống (Protocol & IPC)

Mọi quyết định kiến trúc trong Tuần 1 và Tuần 2 đều nhằm đáp ứng chính xác 2 bản đặc tả cốt lõi của dự án:

### 2.1. Tuân thủ `spec/doc/protocol.md` (Giao thức Mạng & Bảo mật)
- **Cách áp dụng ở Tuần 1:** Đặc tả yêu cầu bắt buộc dùng chuẩn chữ ký ECDSA P-256 và mở rộng X.509. Vì Dart SDK không đủ mạnh để thao tác với OID tùy chỉnh, nên Tuần 1 đã chốt phương án hạ tầng: cài đặt 2 thư viện cấp thấp là `pointycastle` và `asn1lib`.
- **Cách áp dụng ở Tuần 2:** Thực thi chính xác Mục 3.4 của Protocol. File `cert_builder.dart` đã trực tiếp dùng `asn1lib` để bọc *Double OCTET STRING* mảng byte. Qua đó nhúng thành công OID đặc chế (`2.25...`) chứa mã Ed25519 vào chứng chỉ mTLS. Đảm bảo tính đồng nhất 100% với Daemon chạy trên Windows.

### 2.2. Tuân thủ `spec/doc/ipc.md` (Giao tiếp Flutter Client)
- **Cách áp dụng ở Tuần 1:** Xây dựng bộ khung thư mục nghiêm ngặt, tách biệt vùng chứa mã giao tiếp (`ipc/`) và mã nghiệp vụ gốc (`interfaces/`, `crypto/`).
- **Cách áp dụng ở Tuần 2:** Đặc tả IPC yêu cầu kết nối bằng JSON-RPC 2.0 qua Transport-agnostic. Để làm nền móng, Tuần 2 đã tạo ra 5 Abstract Interfaces (`IdentityManager`, `DiscoveryService`...). Đây là lớp trừu tượng (Abstraction Layer) ép code giao tiếp JSON-RPC sau này phải tương tác thông qua nó, giúp Daemon không bị hard-code vào bất kỳ giao thức kết nối cứng nào.

---

## 3. Đánh giá Rủi ro (Risk Assessment) tính đến Tuần 2

1. **Rủi ro Parse Chứng Chỉ (Dự kiến cho Tuần 3):**
   Đã sinh được chứng chỉ thành công ở Tuần 2, nhưng bài toán tiếp theo ở Tuần 3 là trích xuất (Giải mã/Parser) chứng chỉ gửi từ máy tính khác. Yêu cầu đặt ra là phải viết Parser an toàn (Fail-Closed) để chặn các cuộc tấn công chứng chỉ giả.

2. **Rủi ro Dịch vụ mDNS:**
   Tuần 4 sẽ phải tiếp xúc với mDNS Native của OS, rủi ro cao xảy ra lỗi khi tích hợp plugin qua Flutter Isolate.
