# risks_and_notes.md

## Ghi chú và rủi ro quan sát được từ Task 1 Tuần 1

1. Không tương thích phiên bản phụ thuộc
   - `flutter pub get` cảnh báo một số package có phiên bản mới hơn không tương thích với constraint hiện tại.
   - Hành động: lên lịch rà soát phụ thuộc (`flutter pub outdated`) trước khi nâng cấp major.

2. Khác biệt môi trường CI
   - Workflow CI chạy trên `ubuntu-latest`. Các target desktop (Windows/macOS) có thể hành xử khác; việc build desktop trong CI cần runner phù hợp hoặc cấu hình matrix.

3. Khả năng tái tạo test/artefact
   - Đảm bảo tests không phụ thuộc vào đường dẫn môi trường cụ thể; giữ widget tests nhẹ và độc lập.

4. Quy ước đặt tên package
   - Cần tránh dấu gạch ngang trong tên package pub; đã đổi `app-flutter` → `app_flutter`.

5. Thành phần nhạy cảm về bảo mật trong tương lai
   - Trình phân tích ASN.1 cho chứng chỉ (kế hoạch các tuần sau) là phần có rủi ro cao cần fuzzing riêng và test negative vectors.

6. Vệ sinh cấu trúc dự án
   - Giữ `README.md` làm nguồn chính cho deliverable Tuần 1; lưu trữ hoặc xóa file phụ trùng nếu cần.
