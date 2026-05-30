# Rift Android Daemon (Dart) - Hướng dẫn sử dụng & Kiến trúc

Đây là module lõi chạy ngầm (daemon) trên hệ điều hành Android của dự án Rift, được phát triển bằng ngôn ngữ Dart. Nhiệm vụ của module này là giao tiếp bảo mật với Windows Daemon (qua mTLS) và cung cấp dịch vụ cho Flutter UI (qua JSON-RPC).

---

## 1. Cấu trúc thư mục

- `lib/src/interfaces/`: Chứa 5 Interfaces cốt lõi (`IdentityManager`, `TrustStore`, `Transport`, `DiscoveryService`, `ClipboardService`). Mọi thao tác nghiệp vụ phải đi qua các giao diện này.
- `lib/src/crypto/`: Chứa logic mật mã học cực kỳ quan trọng, tiêu biểu là `cert_builder.dart` để tự động bọc mã Ed25519 vào chứng chỉ X.509 bằng kỹ thuật *Double OCTET STRING*.
- `test/`: Chứa các kịch bản kiểm thử bảo mật (Fail-Closed).
- `demo_cert.dart`: Kịch bản mẫu để sinh thử một file chứng chỉ hợp lệ `demo.pem` ra ổ cứng.

---

## 2. Hướng dẫn sử dụng & Các lệnh cơ bản

### 2.1. Cài đặt các gói phụ thuộc
Trước khi làm việc, hãy đảm bảo tải đủ thư viện (`pointycastle`, `asn1lib`):
```bash
dart pub get
```

### 2.2. Kiểm tra chất lượng Code (Linter)
Mọi đoạn code đẩy lên nhánh phải không có cảnh báo. Hệ thống Linter đã được cấu hình khắt khe trong `analysis_options.yaml`.
```bash
dart analyze
```
> **Lưu ý:** Bắt buộc phải hiện `No issues found!` mới được tạo Pull Request.

### 2.3. Chạy Unit Test Bảo mật
Chạy toàn bộ kịch bản test để xác minh module mã hóa sinh đúng mảng byte ASN.1.
```bash
dart test
```
> **Trường hợp Test Thất bại (Fail-Closed):**
> Nếu hệ thống in ra màn hình `Expected: <...>` nhưng `Actual: <...>`, kèm theo thông báo đỏ `Some tests failed. Exit code: 1`. 
> - **Kết luận:** Chứng tỏ mảng byte ASN.1 của chứng chỉ đã bị thao túng hoặc cấu trúc không khớp chuẩn X.509 đặc tả. Cơ chế **Fail-Closed** đã được kích hoạt, đóng sập luồng chạy ngay lập tức.
> - **Hậu quả:** Pull Request của bạn sẽ bị CI/CD chặn hoàn toàn, tuyệt đối không được phép Merge vào nhánh gốc để bảo vệ hệ thống khỏi lỗ hổng Parser.

### 2.4. Chạy kịch bản Demo (Sinh chứng chỉ)
Để thử nghiệm tính năng sinh chứng chỉ tự cấp phát của Tuần 2, bạn có thể chạy lệnh:
```bash
dart run demo_cert.dart
```
Lệnh này sẽ tạo ra một file `demo.pem` ngay tại thư mục gốc. Bạn có thể dùng `openssl x509 -in demo.pem -text -noout` để tự mình kiểm tra cấu trúc bên trong.

---

## 3. Mức độ tuân thủ Đặc tả Hệ thống (Protocol & IPC)
- **Với `protocol.md`:** Đã bám sát 100% yêu cầu mật mã (ECDSA + Ed25519 X.509 Extension) thông qua `cert_builder.dart` ở Tuần 2, sử dụng nền tảng `pointycastle` và `asn1lib` đã dọn sẵn ở Tuần 1.
- **Với `ipc.md`:** Xây dựng 5 Interfaces (Abstract) ở Tuần 2 để tạo màng bọc trừu tượng (Abstraction Layer), dọn đường cho kết nối JSON-RPC 2.0 từ Flutter UI vào thẳng các module nghiệp vụ trong các tuần tới. Không bị Hard-Code vào công nghệ truyền tải.
