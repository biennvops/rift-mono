# Báo cáo Đánh giá & Phân tích Dart Daemon (Tuần 1)

**Đối chiếu chuẩn:** `フィナーレ.md` (Master Plan)
**Thành phần:** Android Daemon (`daemon-dart`)
**Đánh giá bởi:** System Review

---

## Cấu trúc thư mục & Tệp quan trọng (Quy hoạch tại Tuần 1)

```text
daemon-dart/
├── lib/
│   └── src/                   # Thư mục gốc chứa mã nguồn (hiện tại trống, sẽ phát triển ở các tuần tiếp theo)
├── test/                      # Thư mục chứa cấu hình Unit Test ban đầu
├── pubspec.yaml               # Khai báo nền tảng Dart và các thư viện cốt lõi (pointycastle, asn1lib, basic_utils)
└── README.md                  # Hướng dẫn chạy test và Linter
```

---

## 1. Mức độ tuân thủ Task (Theo `フィナーレ.md`)

- **`[daemon-dart][infra]` (Tuần 1):** Khởi tạo cấu trúc Dart daemon cơ bản.
  - Đã cài đặt và kiểm định tính khả dụng của các gói mật mã `pointycastle` và `asn1lib`.
  - Đã thiết lập khung kiểm thử (Test Framework) và Linter.
  - Định hình rõ ràng quy hoạch thư mục chuẩn bị cho các module giao thức.
  - **Đánh giá:** **ĐẠT (100%)**

---

## 2. Đối chiếu Đặc tả Hệ thống (Protocol & IPC)

Dù Tuần 1 chỉ tập trung vào hạ tầng cơ bản, các quyết định nền móng đã được định hướng nghiêm ngặt theo đặc tả của dự án:

- **Đặc tả `spec/doc/protocol.md`:**
  - *Yêu cầu mật mã (Mục 3.4):* Giao thức bắt buộc sử dụng chữ ký **ECDSA P-256** và chứng chỉ mạng X.509 có chứa OID tùy chỉnh.
  - *Kết quả Tuần 1:* Đã lựa chọn và cài đặt thành công `pointycastle` và `asn1lib`. Đây là quyết định hạ tầng cốt lõi vì thư viện mặc định của Dart không đủ khả năng can thiệp sâu vào byte để đáp ứng yêu cầu bảo mật này.
  
- **Đặc tả `spec/doc/ipc.md`:**
  - *Yêu cầu giao tiếp (Mục 2):* Daemon phải giao tiếp với Flutter UI bằng chuẩn **JSON-RPC 2.0** qua Transport-agnostic binding.
  - *Kết quả Tuần 1:* Đang ở trạng thái quy hoạch. (Các thư viện như `json_rpc_2` và cấu trúc module IPC sẽ được triển khai khi hoàn tất tầng mạng).

---

## 3. Đánh giá Rủi ro (Risk Assessment) tính đến Tuần 1

1. **Rủi ro Cấu trúc ASN.1 (Dự kiến cho Tuần 2):**
   Thư viện chuẩn `dart:io` của Dart không hỗ trợ việc nhúng Custom X.509 Extension (chúng ta cần nhúng Ed25519 Public Key vào chứng chỉ mTLS theo chuẩn giao thức). Rủi ro rất cao là chúng ta sẽ phải thao tác trực tiếp với mảng byte ASN.1 bằng tay (Hack ASN.1 Tree) qua thư viện `asn1lib` ở tuần tới.

2. **Rủi ro Kiến trúc:**
   Cần đảm bảo thiết kế module interfaces ở tuần tới phải đồng bộ hoàn toàn với kiến trúc C# Worker Service trên Windows để kiến trúc IPC có thể hoạt động trơn tru.
