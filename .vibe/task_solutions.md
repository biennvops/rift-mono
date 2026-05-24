# task_solutions.md

## Task 1 — Tuần 1: Ghi chú triển khai và các bước tái lập

Tóm tắt: tạo skeleton dự án, wireframes, UI stubs, widget tests và CI baseline cho `app-flutter`.

Bước thực hiện (chi tiết):

1. Tạo wireframes
   - Tệp: `app-flutter/design/wireframes.md`
   - Nội dung: Pairing screen, Trusted devices list, Event log / Operation history, Clipboard transfer status

2. Thêm UI stubs
   - Các file đã thêm:
     - `app-flutter/lib/screens/pairing_screen.dart` (Scaffold + văn bản stub)
     - `app-flutter/lib/screens/trusted_devices_screen.dart`
     - `app-flutter/lib/screens/event_log_screen.dart`

3. Thêm widget tests
   - File test được thêm vào `app-flutter/test/` kiểm tra tiêu đề và văn bản stub cho từng màn hình

4. Sửa tên package Dart (nếu cần)
   - Đảm bảo `app-flutter/pubspec.yaml` chứa `name: app_flutter`
   - Lệnh đã dùng (PowerShell):

```powershell
Set-Location "c:\doan\rift-mono-main\app-flutter"
(Get-Content pubspec.yaml) -replace 'name: app-flutter','name: app_flutter' | Set-Content pubspec.yaml
```

5. Cài phụ thuộc, phân tích mã và chạy test

```powershell
flutter pub get
flutter analyze
flutter test
```

6. Sửa cảnh báo analyzer
   - Chuyển các constructor sang `const ClassName({super.key});` để thỏa lint `use_super_parameters`.

7. Thêm workflow CI
   - Tệp: `.github/workflows/flutter-ci.yml`
   - Các bước: checkout, setup Flutter, `flutter pub get`, `flutter analyze`, `flutter test --coverage`

Tái hiện cục bộ (tối thiểu):

```powershell
# từ thư mục gốc repo
Set-Location "c:\doan\rift-mono-main\app-flutter"
flutter pub get
flutter analyze
flutter test
```

Danh sách file đã tạo/ chỉnh sửa (tóm tắt):

- app-flutter/design/wireframes.md
- app-flutter/lib/screens/*.dart
- app-flutter/test/*_screen_test.dart
- app-flutter/README.md
- .github/workflows/flutter-ci.yml
- app-flutter/pubspec.yaml (sửa tên)
