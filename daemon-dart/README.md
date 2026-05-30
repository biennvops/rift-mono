# Rift Android Daemon (Dart) - Hướng dẫn sử dụng & Kiến trúc

Đây là module lõi chạy ngầm (daemon) trên hệ điều hành Android của dự án Rift, được phát triển bằng ngôn ngữ Dart. Nhiệm vụ của module này là giao tiếp bảo mật với Windows Daemon (qua mTLS) và cung cấp dịch vụ cho Flutter UI (qua JSON-RPC).

---

## 1. Cấu trúc thư mục

- `lib/src/interfaces/`: Chứa 5 Interfaces cốt lõi (`IdentityManager`, `TrustStore`, `Transport`, `DiscoveryService`, `ClipboardService`). Mọi thao tác nghiệp vụ phải đi qua các giao diện này.
- `lib/src/crypto/`: Chứa logic mật mã học cực kỳ quan trọng:
  - `cert_builder.dart`: Tự động bọc mã Ed25519 vào chứng chỉ X.509 bằng kỹ thuật *Double OCTET STRING*.
  - `cert_decoder.dart`: Trình phân tích cú pháp (Parser) X.509 an toàn (Fail-Closed).
  - `identity_manager_impl.dart`: Sinh và lưu trữ khóa Ed25519 (cryptography). Ứng dụng **Atomic Write** chống lỗi hỏng file.
- `lib/src/network/`: 
  - `discovery_service_impl.dart`: Cài đặt gói `nsd` tìm kiếm thiết bị lân cận qua mDNS.
  - `frame_codec.dart`: Định dạng cấu trúc khung truyền tải (Length prefix + JSON, max 32 MiB). Tích hợp sẵn `RiftFrameTransformer` (StreamTransformer) chặn Memory Exhaustion.
  - `session_messages.dart`: Dữ liệu cho bước Session Bootstrap theo phụ lục C.1.
  - `transport_impl.dart`: Thiết lập mTLS `SecureServerSocket` 2 chiều, ép xác minh Ed25519 từ chứng chỉ x509.
- `test/`: Chứa các kịch bản kiểm thử bảo mật (Fail-Closed).
- `lib/src/daemon_isolate.dart`: Cổng vào (Entry point) cho quá trình chạy background (Foreground Service).
- `demo_cert.dart`: Kịch bản mẫu để sinh thử một file chứng chỉ hợp lệ `demo.pem` ra ổ cứng.

---

## 2. Hướng dẫn sử dụng & Các lệnh cơ bản

> **LƯU Ý QUAN TRỌNG:** Mọi lệnh Terminal dưới đây đều **BẮT BUỘC** phải được chạy bên trong thư mục `daemon-dart`. Đảm bảo bạn đã dùng lệnh `cd daemon-dart` trước khi gõ bất cứ lệnh `dart` nào.

### 2.1. Cài đặt các gói phụ thuộc
Trước khi làm việc, hãy đảm bảo tải đủ thư viện (`pointycastle`, `asn1lib`, `cryptography`):
```bash
dart pub get
```

### 2.2. Kiểm tra chất lượng Code (Linter)
Mọi đoạn code đẩy lên nhánh phải không có cảnh báo. Hệ thống Linter đã được cấu hình khắt khe trong `analysis_options.yaml`.
```bash
dart analyze
```
> **Lưu ý:** Bắt buộc phải hiện `No issues found!` mới được tạo Pull Request.

### 2.3. Chạy Unit Test Bảo mật (Hoàn thiện ở Tuần 3)
Hệ thống Test giờ đây bao phủ cả 3 phân hệ mật mã/mạng cốt lõi:
1. **Mã hóa ASN.1 (`crypto_test`):** Xác minh mảng byte sinh ra chứa đúng OID Ed25519.
2. **Giải mã Fail-Closed (`decoder_test`):** Xác minh hệ thống biết cách đập bỏ các chứng chỉ độc hại/sai chuẩn.
3. **Khung mạng Stream (`frame_codec_test`):** Xác minh cơ chế khóa 32 MiB chống ngập lụt RAM.
4. **Định danh `identity_test`:** Xác minh bộ Ghi nguyên tử (Atomic Write) và chuỗi Device ID chuẩn `rift-`.

```bash
dart test
```
> **Trường hợp 1 trong 14 Tests bị Thất bại:**
> Nếu hệ thống in ra thông báo đỏ `Some tests failed. Exit code: 1`, điều này chứng tỏ Hệ thống phòng thủ của ứng dụng đã bị phá vỡ hoặc có lỗi nghiêm trọng:
> - **Lỗi `crypto_test` / `decoder_test`:** Chứng tỏ cấu trúc byte ASN.1 đã bị thao túng, hoặc cơ chế bóc tách Fail-Closed đang gặp lỗi hổng.
> - **Lỗi `frame_codec_test`:** Hệ thống lọc luồng (Stream) đang không hoạt động, nguy cơ bị lọt gói tin quá 32 MiB hoặc bị tràn RAM.
> - **Lỗi `identity_test`:** Cấu trúc Ghi Nguyên tử (Atomic Write) đang thất bại, nguy cơ cao làm hỏng file lưu trữ khóa Ed25519.
> - **Hậu quả chung:** CI/CD sẽ chặn hoàn toàn Pull Request của bạn. Tuyệt đối không được Merge cho đến khi khắc phục xong!

### 2.4. Chạy kịch bản Demo (Sinh chứng chỉ)
Để thử nghiệm tính năng sinh chứng chỉ tự cấp phát của Tuần 2, bạn có thể chạy lệnh:
```bash
dart run demo_cert.dart
```
Lệnh này sẽ tạo ra một file `demo.pem` ngay tại thư mục gốc. Bạn có thể dùng `openssl x509 -in demo.pem -text -noout` để tự mình kiểm tra cấu trúc bên trong.

---

## 3. Kiến trúc Chống chịu lỗi & Bảo vệ dữ liệu (Tuần 4)
Để đối phó với các kịch bản thực tế khi triển khai lên mạng LAN, module đã được gia cố thêm 2 tấm khiên bảo vệ cấp thấp:
- **Anti-Spam mDNS Cache:** Package `nsd` thường xuyên dội bom sự kiện mỗi khi phát hiện lại máy cũ. `DiscoveryServiceImpl` đã tích hợp bộ đệm `Map<String, DiscoveredPeer>` để chặn đứng sự kiện trùng lặp, chỉ đẩy dữ liệu lên Flutter UI khi đó là máy hoàn toàn mới hoặc bị đổi IP, cứu Flutter UI khỏi tình trạng treo máy vì render lại quá nhiều.
- **Unicast mTLS Routing (Anti-Leak):** Trong môi trường có 10 máy kết nối cùng lúc, gửi Broadcast là thảm họa bảo mật. `TransportImpl` đã sử dụng cấu trúc `Map<String, SecureSocket>` (khóa bằng Device ID trích xuất từ chứng chỉ đối phương) để định tuyến đích danh từng tin nhắn, triệt tiêu nguy cơ gửi nhầm dữ liệu nhạy cảm sang máy khác.

---

## 4. Mức độ tuân thủ Đặc tả Hệ thống (Protocol & IPC)
- **Với `protocol.md`:** 
  - Tuần 2: Bám sát 100% yêu cầu mật mã (ECDSA + Ed25519 X.509 Extension) qua `cert_builder.dart`.
  - Tuần 3: Bám sát chuẩn Fail-Closed cho Parser thông qua `cert_decoder.dart`. Mã hóa cấu trúc `Frame Codec` chuẩn xác giới hạn 32 MiB. Đồng thời tuân thủ chuẩn `rift- + Base32` cho Device ID trong module quản lý Identity.
  - Tuần 4: Đã ánh xạ chính xác 100% cấu trúc JSON-RPC payload cho các lệnh `session.hello`, `session.accept`, `session.reject` (theo Phụ lục C.1).
- **Với `ipc.md`:** 
  - Tuần 2-4: Xây dựng và bắt đầu triển khai các Interfaces (Abstract) để tạo màng bọc trừu tượng (Abstraction Layer), dọn đường cho kết nối JSON-RPC 2.0 từ Flutter UI vào thẳng các module nghiệp vụ trong các tuần tới. Không bị Hard-Code vào công nghệ truyền tải.
