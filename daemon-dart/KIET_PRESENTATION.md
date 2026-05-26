# Kịch bản thuyết trình: Báo cáo Tiến độ Dart Daemon (Tuần 1 & Tuần 2)

**Người thuyết trình**: Kiệt (Android Daemon Lead)
**Chủ đề**: Xây dựng móng kiến trúc và giải quyết rủi ro X.509 trên nền tảng Dart.

---

## Lời chào và Giới thiệu

*(👉 **Hành động**: Trình chiếu Slide mở đầu hoặc bật màn hình chia sẻ VS Code ở thư mục gốc `daemon-dart`)*

**"Chào mọi người và thầy cô. Em là Kiệt, phụ trách chính mảng Android Daemon - tức là ứng dụng chạy ngầm trên Android được viết bằng ngôn ngữ Dart.**

**Hôm nay, em xin phép đại diện nhóm trình bày về những thành quả kỹ thuật quan trọng nhất mà team Android Daemon đã đạt được trong Tuần 1 và Tuần 2. Mục tiêu tối thượng của 2 tuần này không phải là làm ra tính năng ngay, mà là 'Rà mìn' – tức là phát hiện sớm và loại bỏ triệt để những rủi ro về mặt công nghệ liên quan đến mật mã (cryptography) trên hệ sinh thái Dart."**

---

## Phần 1: Tuần 1 - Phá vỡ rào cản hệ thống và Đánh giá công nghệ

**"Bước vào Tuần 1, câu hỏi lớn nhất mà em phải đối mặt là: Liệu ngôn ngữ Dart có đủ khả năng can thiệp sâu vào các thuật toán mã hóa thấp tầng để phục vụ cho giao thức bảo mật Rift hay không?"**

*(👉 **Hành động**: Mở file `bin/cert_spike.dart` lên trên VS Code để show code khởi tạo khóa ECDSA)*

**"Đầu tiên, em tiến hành thiết lập project và làm một bài test nhỏ gọi là 'Smoke Test' với thư viện PointyCastle. Rất đáng mừng, em đã khởi tạo thành công cặp khóa ECDSA P-256 và sinh được chứng chỉ tự ký (self-signed). Điều này chứng minh Dart hoàn toàn có thể tự gánh vác khâu mã hóa mà không cần dựa dẫm quá nhiều vào native code của Android."**

*(👉 **Hành động**: Mở Terminal, gõ lệnh `dart run bin/cert_spike.dart` và bôi đen phần output màu xám báo cáo "dart:io limitations")*

**"Tuy nhiên, rủi ro lớn nhất đã xuất hiện. Khi đánh giá thư viện chuẩn `dart:io` do Google cung cấp, em phát hiện ra nó 'bị mù' hoàn toàn trước các bộ mở rộng tùy chỉnh (Custom X.509 Extensions). Nghĩa là, nó không cho phép chúng ta nhét Device ID (khóa Ed25519) vào chứng chỉ mạng. Nếu không có Device ID, giao thức mTLS của dự án Rift sẽ sụp đổ hoàn toàn.**

**Chính nhờ phát hiện sớm này trong Tuần 1, em đã kịp thời chốt phương án bẻ lái cho Tuần 2: Bắt buộc phải tự tay viết bộ phân tích cú pháp (parser) chuẩn ASN.1."**

---

## Phần 2: Tuần 2 - Định hình Kiến trúc & Làm chủ ASN.1

*(👉 **Hành động**: Chuyển sang mở bung cây thư mục `lib/src/interfaces/` để mọi người thấy rõ 5 file interface được định nghĩa gọn gàng)*

**"Sang Tuần 2, em bắt tay vào giải quyết bài toán cốt lõi. Nhiệm vụ đầu tiên là phải đảm bảo Android Daemon có chung một tiếng nói và cấu trúc với Windows Daemon do Thạo phát triển.**

**Vì vậy, em đã hoàn thành bộ khung 5 Interface cốt lõi gồm: IdentityManager, TrustStore, Transport, DiscoveryService, và ClipboardService. Sự đồng bộ này đảm bảo khi hệ thống IPC kết nối với giao diện Flutter của Kim, nó sẽ chạy mượt mà bất kể ở dưới là Windows hay Android."**

*(👉 **Hành động**: Mở file `lib/src/crypto/cert_builder.dart` và bôi đen dòng code khai báo OID bằng raw bytes `0x06, 0x09, 0x2B...`)*

**"Và đặc biệt nhất, em đã giải quyết thành công 'điểm chết' của Tuần 1. Em đã tự viết một class mang tên `RiftCertBuilder` sử dụng thư viện `asn1lib`. Thay vì dùng các API có sẵn, em đã dùng kỹ thuật ghi byte thô (raw bytes) để dựng lên một khối cấu trúc `ASN1Sequence` chuẩn chỉnh. Khối này bao gồm một OID tự định nghĩa, cờ Critical, và khóa Ed25519. Cuối cùng, chúng ta đã có thể ép hệ thống nhét Device ID vào chứng chỉ mạng đúng như bản đặc tả giao thức của anh Biên đề ra."**

*(👉 **Hành động**: Mở file `test/crypto_test.dart` lên, sau đó quay lại Terminal, gõ lệnh `dart test`. Chờ chạy xong rồi chỉ chuột vào dòng chữ "All tests passed!")*

**"Để chứng minh code hoạt động chuẩn, em đã viết Unit Test và kết quả là Pass 100%. Các node ASN.1 sinh ra hoàn toàn khớp với định dạng quốc tế."**

---

## Lời Kết

*(👉 **Hành động**: Có thể tắt chế độ share VS Code hoặc chuyển về slide tổng kết của nhóm)*

**"Tóm lại, chỉ trong 2 tuần đầu tiên, nhánh Android Daemon đã giải quyết xong toàn bộ những vùng tối nguy hiểm nhất về mặt công nghệ mã hóa trên nền tảng Dart. Nền móng kiến trúc hiện tại đã cực kỳ vững chắc. Nhóm hoàn toàn tự tin để bước sang Tuần 3 và 4: Khởi chạy kết nối mDNS và thiết lập đường hầm bảo mật mTLS.**

**Cảm ơn mọi người đã lắng nghe. Em xin phép nhường lời lại cho các thành viên khác trình bày về tiến độ của mình."**
