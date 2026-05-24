# weekly_tasks.md

## Tuần 1 — Kim (Flutter & QA Lead)

Trạng thái: Hoàn thành (Task 1)

Các nhiệm vụ:

- Task 1: Khởi tạo project shell + wireframes + UI stubs + widget tests + CI baseline
  - Chủ sở hữu: Kim
  - Trạng thái: Hoàn thành
  - Mục đã hoàn thành:
    - Tạo wireframes: `app-flutter/design/wireframes.md`
    - Tạo UI stubs: `app-flutter/lib/screens/pairing_screen.dart`, `trusted_devices_screen.dart`, `event_log_screen.dart`
    - Tạo widget tests: `app-flutter/test/*_screen_test.dart`
    - Thêm workflow CI: `.github/workflows/flutter-ci.yml`
    - Sửa tên package: `pubspec.yaml` (name: app_flutter)
    - Sửa constructors để dùng `super.key` theo gợi ý analyzer
    - Gộp README, danh sách issue và bằng chứng vào `app-flutter/README.md`
    - Tạo `app-flutter/week1-task1-complete.md` làm mẫu bằng chứng
  - Tiêu chí chấp nhận đã kiểm tra:
    - `flutter pub get` chạy thành công
    - `flutter analyze` trả về `No issues found!`
    - `flutter test` pass (All tests passed)

Ghi chú:
- Xem `.vibe/task_solutions.md` và `.vibe/risks_and_notes.md` để biết chi tiết kỹ thuật và các rủi ro.
