# Báo cáo: Thử nghiệm (Spike) Dart Daemon - Tuần 1

**Người thực hiện**: Antigravity (AI Assistant) thay mặt cho Kiệt (Android Daemon Lead).
**Mục tiêu**: Hoàn thành nhiệm vụ Tuần 1 - Nghiên cứu kiến trúc Dart daemon và kiểm chứng khả năng tạo chứng chỉ ECDSA P-256 tự ký (self-signed) bằng thư viện PointyCastle, đồng thời đánh giá giới hạn của `dart:io`.

## 1. Khởi tạo Dự án
- **Thư mục**: `daemon-dart`
- Lệnh được sử dụng để khởi tạo khung console ứng dụng:
  ```bash
  dart create --force .
  ```
- **Thư viện cài đặt**:
  - `pointycastle`: Thư viện mã hóa cốt lõi.
  - `asn1lib`: Hỗ trợ thao tác với chuẩn ASN.1.
  - `basic_utils`: Cung cấp các tiện ích X509 cấp cao (bọc bên ngoài PointyCastle) giúp việc sinh CSR và chứng chỉ dễ dàng hơn.

## 2. Chi tiết mã thử nghiệm (Smoke Test)
Mã nguồn được viết tại: `bin/cert_spike.dart`.

**Quy trình xử lý trong mã**:
1. **Khởi tạo cặp khóa ECDSA P-256**: Sử dụng `CryptoUtils.generateEcKeyPair(curve: 'prime256v1')`.
2. **Sinh CSR (Certificate Signing Request)**: Hàm `X509Utils.generateEccCsrPem()` được dùng để đóng gói Public Key và các thuộc tính (VD: `CN: Rift Device`) thành một yêu cầu ký.
3. **Tự ký chứng chỉ (Self-signed)**: Dùng Private Key vừa tạo để ký lên CSR thông qua `X509Utils.generateSelfSignedCertificate()`, từ đó xuất ra chứng chỉ chuẩn X.509 định dạng PEM.

## 3. Kết quả đánh giá giới hạn của `dart:io`
Thông qua quá trình code spike, tôi đã đánh giá class `X509Certificate` có sẵn trong thư viện chuẩn `dart:io` của Flutter/Dart:
- `X509Certificate` **chỉ hỗ trợ đọc** các thuộc tính cơ bản (như `issuer`, `subject`, `start`, `end`, và nội dung `pem`).
- Nó **không cung cấp bất kỳ API nào** để phân tích cú pháp (parse) hoặc nhúng các Custom X.509 Extensions (chẳng hạn như Object Identifier - OID tùy chỉnh để chứa Public Key Ed25519 của giao thức Rift).
- **Kết luận**: Bắt buộc phải sử dụng parser ASN.1 tùy chỉnh (thông qua `pointycastle` và `asn1lib`) cho các tính năng bảo mật sâu hơn (nhúng Device ID) ở các tuần tiếp theo.

## 4. Cách chạy thử nghiệm
Để kiểm chứng lại kết quả công việc, có thể chạy lệnh sau tại thư mục `daemon-dart`:
```bash
dart run bin/cert_spike.dart
```
Output sẽ hiển thị chi tiết quá trình tạo khóa, in ra nội dung chứng chỉ PEM, và các kết luận đánh giá.

## 5. Tại sao lại có kết quả này?
Kết quả ở terminal chứng minh hai sự thật quan trọng về hệ sinh thái Dart/Flutter hiện tại đối với dự án Rift:
1. **Khả năng mã hóa hoàn chỉnh:** Output khối `-----BEGIN CERTIFICATE-----` xác nhận rằng thư viện PointyCastle (thông qua lớp bọc `basic_utils`) hoàn toàn đủ khả năng sinh khóa ECDSA P-256 và tự ký chứng chỉ thành công. Điều này giải quyết rủi ro thiếu hụt thuật toán ở cấp thấp (điều mà ban đầu team chưa dám chắc).
2. **Sự nghèo nàn của thư viện chuẩn:** Đánh giá giới hạn của `dart:io` cho thấy kết quả như vậy là do Apple/Google thiết kế thư viện `dart:io.X509Certificate` chỉ nhằm mục đích phục vụ TLS client/server thông thường (để gọi API web). Nó không được sinh ra để làm một công cụ PKI (Public Key Infrastructure) toàn diện. Đó là lý do tại sao nó hoàn toàn "mù" trước các Custom X.509 Extensions (nơi Rift cần nhét khóa Ed25519 vào).

## 6. Mã thử nghiệm như thế này đã đủ chưa?
**Trả lời: Hoàn toàn ĐỦ cho nhiệm vụ Tuần 1.**

Mục tiêu của một "Spike" trong quy trình phần mềm (Agile) không phải là viết code sạch đẹp để đưa vào sản phẩm cuối cùng. Mục tiêu của nó là **trả lời các câu hỏi về rủi ro kỹ thuật (technical risks) tốn ít thời gian nhất**. Bài test này đã hoàn thành xuất sắc sứ mệnh của nó bằng việc chốt hạ 2 vấn đề lớn:
1. PointyCastle có tạo được chứng chỉ ECDSA P-256 không? **(Đã chứng minh là CÓ)**
2. Có thể dùng "lười" thư viện `dart:io` để tiết kiệm công sức được không? **(Đã chứng minh là KHÔNG, bắt buộc phải tự code parser ASN.1)**

Với kết quả này, Kiệt (Android Lead) đã có đủ cơ sở kỹ thuật vững chắc để tự tin bước sang Tuần 2 & 3: Bắt tay vào viết Custom X.509 ASN.1 parser và xây dựng các cấu trúc thực tế cho Daemon mà không sợ bị "đứt gánh giữa đường" vì chọn sai công nghệ. Công việc "nghiên cứu rủi ro" của Tuần 1 cho Dart như vậy là viên mãn!
