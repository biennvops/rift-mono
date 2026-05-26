# Rift

Rift là nền tảng liên kết thiết bị đa nền tảng ưu tiên bảo mật.

Kho lưu trữ này chứa đặc tả giao thức, các triển khai daemon, ứng dụng Flutter và các bài kiểm thử mức độ tương thích/khả năng hoạt động liên thông. Đặc tả giao thức là nguồn gốc chuẩn xác cho các triển khai tương thích.

## Cấu trúc thư mục

- `spec/` - Đặc tả giao thức Rift độc lập với ngôn ngữ và các tài liệu hỗ trợ.
- `daemon-cs/` - Triển khai daemon Windows bằng C#/.NET.
- `daemon-dart/` - Triển khai daemon Android bằng Dart.
- `app-flutter/` - Ứng dụng Flutter dành cho Android và Windows.
- `tests-conformance/` - Các bài kiểm thử mức độ tương thích của triển khai với giao thức được viết.
- `tests-interop/` - Các bài kiểm thử khả năng hoạt động liên thông giữa các triển khai.

## Đặc tả giao thức

Bắt đầu tại `spec/doc/protocol.md`.

Các quyết định về kiến trúc nằm trong `spec/decisions/`.

Các tài liệu tham khảo nội bộ có thể được đặt trong `spec/references/`; thư mục này được cố ý không đưa vào hệ thống quản lý phiên bản (not committed).

## Trạng thái

Khung cấu trúc không gian làm việc ban đầu.
