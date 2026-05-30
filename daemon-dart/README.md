# Rift Android Daemon (Dart) - Hướng dẫn sử dụng & Tổng kết

Đây là module lõi chạy ngầm (daemon) trên hệ điều hành Android của dự án Rift, được phát triển bằng ngôn ngữ Dart.

---

## 1. Hướng dẫn sử dụng & Các lệnh cơ bản

Dưới đây là các câu lệnh cơ bản để làm việc với codebase của thư mục `daemon-dart` (Tuần 1):

### Chạy Unit Test (Kiểm tra môi trường)
Đảm bảo hệ thống Dart đã cài đặt đúng các package và môi trường chạy trơn tru.
```bash
dart test
```

### Phân tích mã nguồn (Dart Linter)
Kiểm tra xem code có vi phạm các quy tắc format hay naming convention của Dart hay không.
```bash
dart analyze
```
- **Thành công (`No issues found!`):** Code sạch 100%, đáp ứng tiêu chuẩn.
- **Thất bại:** Báo lỗi Warning. Kiên quyết không Push code lên Git nếu lệnh này chưa ra màu xanh.

---

## 2. Kết luận: Thành quả Tuần 1 (Hoàn thành 100%)

Trong Tuần 1 của dự án, Kiệt (Android Daemon Lead) đã hoàn thành xuất sắc mục tiêu "Khởi tạo hạ tầng" (`[daemon-dart][infra]`) được giao trong `finaltask.md`:

1. **Thiết lập Hạ tầng Core:**
   - Đã khởi tạo thành công project Dart chuẩn (`daemon-dart`).
   - Tích hợp thành công các thư viện mật mã cốt lõi: `pointycastle` (dành cho ECDSA P-256), `asn1lib` (để xử lý mảng byte ASN.1), và `basic_utils`.

2. **Dọn dẹp Lỗi & Clean Code:**
   - Đã xử lý triệt để các cảnh báo Linter của Dart.
   - Codebase đã sạch sẽ, chuẩn bị sẵn sàng cho việc xây dựng kiến trúc Interface và mã hóa X.509 ở Tuần 2.
