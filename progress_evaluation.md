# Báo cáo Đánh giá Tiến độ Dự án Rift-Mono (Tuần 1 & Tuần 2)

Dựa trên bản thiết kế **Rift v0.1 Master Plan** (`フィナーレ.md`) và trạng thái hiện tại của workspace, dưới đây là đánh giá chi tiết về tiến độ của toàn bộ **4 thành viên** trong team.

## 1. Tình hình chung của `rift-mono`
Dự án hiện đang hoàn tất các cột mốc của **Tuần 1 (Project Alignment & Spec Lockdown)** và **Tuần 2 (Protocol Test Vectors & Core Architecture)**.
Tiến độ của các team lập trình daemon backend (Thạo, Kiệt) rất khả quan và đã giải quyết được các điểm rủi ro phức tạp. Tuy nhiên, phần cốt lõi về Spec (Biên) đang bị chậm ở mảng cung cấp dữ liệu tham chiếu (Test Vectors) dẫn đến việc block 2 daemon ở bước tiếp theo, và mảng Giao diện/Kiểm thử (Kim) chưa có dấu hiệu khởi động.

---

## 2. Tiến độ của Biên (Protocol & Security Lead)
Biên chịu trách nhiệm làm nền móng kỹ thuật và bảo mật cho toàn bộ dự án thông qua `spec/` và `tests-conformance/`.
- **Tuần 1 (Hoàn thành rất tốt):** Đã thiết lập cấu trúc repo. Viết xong bộ 10 tài liệu quyết định kiến trúc (ADR-0001 đến ADR-0010) trong thư mục `spec/decisions/`. File đặc tả giao thức gốc `spec/doc/protocol.md` đã được soạn thảo rất chi tiết.
- **Tuần 2 (Đang chậm trễ):** Theo plan, Tuần 2 cần có các **Test Vectors** (bộ dữ liệu test mẫu đã mã hóa) và **Conformance test runner harness**. Tuy nhiên, thư mục `spec/vectors/` và `tests-conformance/` hiện tại vẫn đang trống (chỉ có file README).
- ⚠️ **Hệ quả:** Việc chậm trễ cung cấp Test Vectors đang trở thành "nút thắt cổ chai", trực tiếp chặn (block) tiến độ của Thạo và Kiệt không thể làm tiếp phần Identity và Frame Codec ở Tuần 3.

---

## 3. Tiến độ của Kiệt (Android Daemon Lead)
Kiệt đã hoàn thành xuất sắc và đúng hạn 100% nhiệm vụ (issues) Tuần 1 và Tuần 2:
- ✅ `[daemon-dart][infra]`: Khởi tạo cấu trúc thư mục, cài đặt các package mật mã (`pointycastle`, `asn1lib`). Thử nghiệm sinh chứng chỉ ECDSA P-256 thành công.
- ✅ `[daemon-dart] Module interfaces`: Tạo xong 5 interface cốt lõi (`IdentityManager`, `TrustStore`, `Transport`, `DiscoveryService`, `ClipboardService`) đồng bộ với kiến trúc C# của Thạo.
- ✅ `[daemon-dart][risk-cert-interop]`: Giải quyết triệt để rủi ro kỹ thuật (Critical Risk) lớn nhất của nền tảng Dart bằng việc tự viết class `RiftCertBuilder`. Ứng dụng đã có thể đóng gói OID tuỳ chỉnh và Device ID vào chứng chỉ thông qua Custom ASN.1 sequence.
- ✅ `[daemon-dart][test]`: Đã viết và chạy thành công bộ unit test nền tảng (`crypto_test.dart`, `interfaces_test.dart`).
- ⏸️ **Trạng thái:** Đang chờ Biên tung ra Test Vectors để xác thực code.

---

## 4. Tiến độ của Thạo (Windows Daemon Lead)
Thạo cũng đã bám sát kế hoạch và hoàn thành 100% nhiệm vụ nền tảng:
- ✅ `[daemon-cs][infra]`: Setup thành công .NET 10 Worker Service. Lựa chọn và ghi tài liệu đầy đủ lý do dùng thư viện (BouncyCastle, Makaretu...). Hệ thống IPC (Named Pipes) thông qua `IpcListener.cs` đã được dựng sẵn.
- ✅ `[daemon-cs] Module interfaces and DI setup`: Định nghĩa xong các interface nền tảng (nằm trong `Interfaces/`) và thiết lập cơ chế Mock Services chuẩn bị cho Dependency Injection.
- ✅ `[daemon-cs][test] Unit test skeleton`: Dựng xong project kiểm thử `daemon-cs.Tests` với bộ khung đã sẵn sàng để tải file Test Vectors (`VectorLoader.cs`, `ConformanceTests.cs`).
- ⏸️ **Trạng thái:** Tương tự Kiệt, đang chờ Biên tung ra Test Vectors để đi tiếp.

---

## 5. Tiến độ của Kim (Flutter & QA Lead)
Kim phụ trách phần ứng dụng người dùng (`app-flutter/`), các bài test tích hợp E2E (`tests-interop/`) và hệ thống CI (GitHub Actions).
- **Tuần 1 & Tuần 2 (Đang chậm trễ nghiêm trọng):**
  - Theo plan phải có "Flutter app shell" và UI Wireframes, nhưng hiện tại thư mục `app-flutter/` chỉ có duy nhất một file README.
  - Chưa thiết lập hệ thống CI `.github/workflows/` (không tồn tại).
  - Chưa có bộ khung test và code IPC cho Dart/Windows trong `tests-interop/`.
- ⚠️ **Hệ quả:** Kim cần khẩn trương bắt kịp vì dự án phụ thuộc vào CI để tự động chấm điểm code (Conformance Suite) và chạy test kết nối thực tế ở các tuần tới.

---

## 6. Tổng kết & Hành động khẩn cấp
- **Dành cho Thạo & Kiệt:** Tiến độ rất hoàn hảo, đã chủ động xử lý được các rủi ro cốt lõi. Trong thời gian chờ đợi, hai bạn có thể nghiên cứu trước tài liệu mDNS và cách tích hợp TLS cho tuần tới.
- **Dành cho Biên:** Cần ưu tiên **Mức độ 1 (P0)** cho việc sinh các tệp Test Vectors (Identity, Frame envelope, Cert DER) và thiết lập Conformance Test Runner để gỡ block cho 2 team Daemon.
- **Dành cho Kim:** Phải lập tức tạo khởi tạo project Flutter và thiết lập luồng CI cơ bản để đảm bảo đến hạn chốt (Thứ Sáu của Tuần 3) hệ thống tự động đã sẵn sàng.
