# Báo cáo Prototype: Rift Protocol (v0.1-draft)

Báo cáo này mô tả cấu trúc và các thành phần của bản prototype Flutter được xây dựng để kiểm chứng các concept bảo mật cốt lõi của giao thức Rift.

## Cấu trúc thư mục (app-flutter/)

Prototype được cấu trúc dưới dạng một ứng dụng Flutter (Dart) tiêu chuẩn:

```
app-flutter/
├── pubspec.yaml            # Cấu hình dependencies (crypto, base32, uuid)
└── lib/
    ├── main.dart           # Giao diện chính (UI) chia 2 màn hình Device A và Device B
    ├── crypto_utils.dart   # Logic mã hóa: Ed25519, dẫn xuất Device ID và Fingerprint
    └── mock_transport.dart # Mô phỏng kết nối mTLS và vận chuyển JSON Envelope
```

## Các vấn đề của Protocol đã được giải quyết / chứng minh trong Prototype

Bản prototype này đã implement và trực quan hóa các yêu cầu khắt khe sau đây của `protocol.md`:

### 1. Dẫn xuất định danh (Identity Derivation) - Giải quyết CVE-2025-66270
- **Vấn đề**: Các giao thức cũ thường cho phép thiết bị tự nhận ID của mình (dẫn đến giả mạo - Spoofing).
- **Trong Prototype (`crypto_utils.dart`)**: Device ID không phải là một chuỗi ngẫu nhiên. Nó bắt buộc được băm (SHA-256) từ 32-byte public key của Ed25519, sau đó encode bằng Base32 không padding và thêm tiền tố `rift-`.
- **Kết quả**: Bất kỳ ai muốn giả mạo Device A đều phải có Private Key của Device A.

### 2. Xác minh vân tay trực quan (Visual Fingerprint) - Giải quyết CVE-2025-32898
- **Vấn đề**: Sử dụng mã pin ngắn (như 6 số) rất dễ bị tấn công brute-force hoặc MitM (Man-in-the-middle).
- **Trong Prototype (`crypto_utils.dart` & `main.dart`)**: Vân tay (Fingerprint) được tạo ra từ việc băm Public Key, cắt thành 32 ký tự in hoa và chia làm 8 nhóm (Ví dụ: `ABCD-EFGH-IJKL-...`). 
- **Kết quả**: Giao diện hiển thị rõ ràng mã vân tay này trên cả hai Device. Người dùng phải xác nhận hai chuỗi dài này khớp nhau để chuyển trạng thái từ `pairing_pending` sang `trusted`.

### 3. Cấu trúc tin nhắn tiêu chuẩn (JSON Envelope)
- **Vấn đề**: Cần một chuẩn chung để đóng gói mọi hành động.
- **Trong Prototype (`mock_transport.dart`)**: Class `Envelope` ép buộc mọi tin nhắn phải có `rift: "0.1-draft"`, `type`, `messageId` (UUIDv4), `sourceDeviceId` và `payload`.

### 4. Máy trạng thái tin cậy (Trust State Machine)
- **Vấn đề**: Thiết bị không được phép thực hiện hành động nhạy cảm nếu chưa được verify.
- **Trong Prototype (`main.dart`)**: Trạng thái bắt đầu luôn là `Discovered`. Chỉ khi thông điệp `pairing.start` và `pairing.approve` hoàn tất, trạng thái mới chuyển sang `Trusted`. Tính năng chia sẻ Clipboard (`clipboard.offer`) bị ẩn đi và vô hiệu hóa nếu trạng thái không phải là `Trusted`.

### 5. Chia sẻ Clipboard lười biếng (Lazy Clipboard Fetch)
- **Vấn đề**: Đẩy toàn bộ clipboard qua mạng ngay lập tức gây lãng phí băng thông và nguy cơ bảo mật nếu bên kia không muốn nhận.
- **Trong Prototype (`main.dart`)**: Khi Device B muốn chia sẻ, nó không gửi nội dung, nó gửi thông điệp `clipboard.offer` chỉ chứa siêu dữ liệu (metadata: byteSize, sha256, expiresInMs). Việc fetch thực sự được tách biệt.
