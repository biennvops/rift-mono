# Nhiệm Vụ 12 Tuần — Kim (Flutter & QA Lead)

**Vai trò chính:** Flutter & QA Lead — chịu trách nhiệm `app-flutter/`, pairing UI, quản lý trust UI, system tray trên Windows, `tests-interop/`, tự động hóa CI test, phân loại bug và QA sign-off.

## Tóm tắt mục tiêu
Kim chịu trách nhiệm giao diện người dùng, trải nghiệm pairing/trust, tự động hoá test liên-kết (interop), và đảm bảo CI/QA ổn định cho toàn dự án.

## Tuần 1 — Project shell & CI
- Tạo skeleton dự án Flutter cho Android và Windows.
- Thiết kế wireframes cho màn hình pairing, quản lý thiết bị tin cậy và event log.
- Khởi tạo CI skeleton (GitHub Actions): lint, build Flutter, chạy unit tests.

## Tuần 2 — IPC & tests cơ bản
- Spike IPC giữa app và daemon: named pipe (Windows) và isolate/channel (Android).
- Viết unit/widget test skeleton cho các màn hình chính.

## Tuần 3 — Debug UI & parser robustness
- Tạo màn hình Settings/Debug hiển thị `device ID` và `fingerprint` cục bộ.
- Viết test cho UI đảm bảo hiển thị đúng dữ liệu, bao gồm trường hợp input malformed.

## Tuần 4 — Discovery UI & integration tests
- Hiện danh sách thiết bị discovered và trusted với UI thích hợp.
- Viết integration test cho flow discovery; thêm test mô phỏng network drop.

## Tuần 5 — Pairing flow & E2E
- Thiết kế màn hình phê duyệt pairing với so sánh fingerprint.
- Viết automated E2E pairing test (Win ↔ Android).

## Tuần 6 — Presence & capability UI
- Hiện trạng thái presence (online/offline) và capability summary cho mỗi peer.
- Thêm test heartbeat-latency và đảm bảo cập nhật UI kịp thời.

## Tuần 7 — Clipboard UX & tray behavior
- Giao diện trạng thái transfer clipboard (offer/fetch/progress/result).
- Đảm bảo app trên Windows chạy ở chế độ tray-resident (đóng cửa sổ không dừng clipboard monitor).
- Thực hiện E2E clipboard test (Win ↔ Android).

## Tuần 8 — Operation history & event log
- UI lịch sử operation và event log có filter/search.
- Kiểm tra các kịch bản lỗi (network drop, daemon kill, malformed input) đảm bảo không crash.

## Tuần 9 — Revoke/Block UI & security visibility
- Màn hình revoke/block với xác nhận và undo nếu phù hợp.
- Hiển thị rõ các event liên quan security trong event log để hỗ trợ điều tra.
- Hợp tác với Biên để chạy các security tests và kiểm tra báo cáo.

## Tuần 10 — Demo automation & bug triage
- Tự động hoá đường dẫn demo (demo script) và test case cho smoke test.
- Hỗ trợ bug triage: tập trung fix P0/P1 và ổn định test trong CI.

## Tuần 11 — Polish, packaging & final regression
- UI polish: thông báo lỗi, trạng thái rỗng, trạng thái tải.
- Soạn kịch bản demo, chụp màn hình, chạy regression cuối cùng.
- Chuẩn bị final test report.

## Tuần 12 — Freeze, smoke test & defense
- Dừng feature work; thực hiện smoke test hàng ngày theo checklist.
- Chạy 2 lần demo dry-run; chuẩn bị slide trình bày UX & QA.
- Hỗ trợ buổi bảo vệ/demos và thu thập feedback cuối cùng.

## Gợi ý issue GitHub
- Tạo các issue chi tiết cho Tuần 1–2 (full descriptions) và tạo stub titles cho Tuần 3–12 để fill-in tuần trước đó.
- Ví dụ issue names:
  - `[app-flutter][infra] Flutter app shell for Android and Windows`
  - `[app-flutter][ux] Pairing approval UI with fingerprint comparison`
  - `[tests-interop] Automated E2E pairing test (Win ↔ Android)`

---
File này được tạo tự động từ `フィナーレ.md` để tách riêng nhiệm vụ 12 tuần cho Kim. Muốn tôi tạo các issue GitHub cho Tuần 1–2 bây giờ không?