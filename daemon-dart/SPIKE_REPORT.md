# Báo cáo: Tiến độ Dart Daemon - Tuần 1 & 2

**Người thực hiện**: Kiệt (Android Daemon Lead)

## 1. Tổng quan
Báo cáo này tổng hợp kết quả công việc trong 2 tuần đầu tiên của dự án Rift đối với thành phần Android Daemon (viết bằng Dart). Mục tiêu chính là loại bỏ các rủi ro công nghệ cốt lõi và thiết lập bộ khung kiến trúc vững chắc cho giao thức bảo mật.

## 2. Kết quả Tuần 1: Khởi tạo và Kiểm chứng Rủi ro (Spike)
- **Khởi tạo dự án:** Setup thư mục `daemon-dart` với các gói thư viện quan trọng: `pointycastle`, `asn1lib`, và `basic_utils`.
- **Smoke test sinh chứng chỉ:** Khởi tạo thành công thử nghiệm (`bin/cert_spike.dart`) việc sinh cặp khóa ECDSA P-256 và tự ký chứng chỉ PEM. Thử nghiệm này xác nhận PointyCastle hoàn toàn đủ khả năng cung cấp các thuật toán mã hóa thấp tầng cho Rift.
- **Đánh giá giới hạn `dart:io`:** Phát hiện quan trọng là class `X509Certificate` của thư viện chuẩn Dart chỉ hỗ trợ đọc cơ bản, hoàn toàn không hỗ trợ nhúng hoặc trích xuất Custom X.509 Extensions. Điều này giúp team chốt phương án bắt buộc phải tự viết bộ Custom ASN.1 parser.

## 3. Kết quả Tuần 2: Core Architecture & Custom ASN.1 Builder
- **Khởi tạo Module Interfaces:** Đã thiết kế và hoàn thiện 5 interface cốt lõi tại `lib/src/interfaces/`:
  - `IdentityManager`, `TrustStore`, `Transport`, `DiscoveryService`, `ClipboardService`.
  - Bộ interface này đảm bảo kiến trúc của Dart Daemon khớp 1:1 với C# Worker Service của Thạo.
- **Custom X.509 Extension (`asn1lib`):** Giải quyết dứt điểm vấn đề rủi ro của Tuần 1 bằng class `RiftCertBuilder`. Sử dụng `asn1lib`, hệ thống đã cấu trúc thành công `ASN1Sequence` bao gồm OID tuỳ chỉnh (sử dụng raw bytes), cờ Critical, và khóa bảo mật Ed25519 (`ASN1OctetString`). Qua đó, Device ID có thể được nhúng trực tiếp vào chứng chỉ TLS theo chuẩn giao thức.
- **Unit Test (Pass 100%):** Hoàn thành việc viết bộ khung test (`crypto_test.dart` và `interfaces_test.dart`). Hệ thống xác nhận các node ASN.1 extension được thiết lập chuẩn xác với OID và định dạng tương ứng. Codebase Dart hiện đã sẵn sàng để đối chiếu với các Test Vectors chuẩn từ Biên (Protocol Lead).

## 4. Tổng kết
Chỉ trong hai tuần đầu, hệ thống Android Daemon đã vượt qua được toàn bộ các điểm mù và rủi ro rào cản công nghệ phức tạp nhất liên quan đến X.509 và hệ sinh thái mật mã của Dart. Nền tảng kiến trúc hiện tại đã rất ổn định để chuẩn bị tích hợp mDNS và mTLS ở những tuần tiếp theo!
