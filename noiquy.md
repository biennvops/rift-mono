 AI Working Rules & Protocol

## 1. Mục tiêu chung
AI phải hoạt động theo nguyên tắc:
- Tuân thủ kế hoạch đã thống nhất.
- Tuân thủ protocol, architecture và coding standards.
- Không tự ý thay đổi phạm vi công việc.
- Không suy diễn hoặc tự bịa ra logic khi chưa được xác nhận.
- Luôn minh bạch trạng thái hiện tại của hệ thống.

---

# 2. Quy tắc bắt buộc

## 2.1 Tuân thủ kế hoạch trong フィナーレ.md
- Chỉ thực hiện đúng task nằm trong kế hoạch.
- Nếu phát sinh thay đổi:
  - Phải báo trước.
  - Giải thích lý do.
  - Đợi xác nhận nếu thay đổi ảnh hưởng logic/system.

AI không được:
- Tự thêm feature.
- Tự optimize ngoài phạm vi yêu cầu.
- Tự đổi kiến trúc.
- Tự bỏ bước trong workflow.

---

## 2.2 Tuân thủ Protocol trong docs/protocol.md và docs/ipc.md
AI phải:
- Tuân thủ protocol đã định nghĩa.
- Tuân thủ flow xử lí dữ liệu.
- Tuân thủ naming convention.
- Tuân thủ dependency boundaries.
- Tuân thủ security rules.

Không được:
- Bypass validation.
- Bypass business logic.
- Gọi trực tiếp resource trái kiến trúc.
- Truy cập chéo module không đúng design.

---

## 2.3 Không Hardcode
Nghiêm cấm:
- Hardcode API URL.
- Hardcode token/key.
- Hardcode config.
- Hardcode business rules.
- Hardcode path/environment values.

Bắt buộc:
- Dùng env/config/constants.
- Dùng abstraction phù hợp.
  - Viết code có khả năng maintain và scale.

---

## 2.4 Đồng bộ Tài liệu và Báo cáo (Documentation Sync)
Khi hoàn thành một task lớn hoặc bước sang Tuần/Giai đoạn mới, AI BẮT BUỘC phải:
- Rà soát toàn bộ các file tài liệu (`README.md`, `SPIKE_REPORT.md`, `plan.md`...).
- Cập nhật tự động Tiêu đề, số liệu thống kê (ví dụ: số lượng test), cấu trúc thư mục mới nhất.
- Chống tuyệt đối hiện tượng "Code thực tế đi trước, Tài liệu cũ kỹ lạc hậu theo sau". Mọi cảnh báo lỗi hoặc mô tả Test thất bại phải bao hàm đầy đủ ngữ cảnh hiện tại.

---

# 3. Quy tắc báo cáo trạng thái

Sau mỗi lần thực hiện cần báo:

## Đã hoàn thành
- Những gì đã làm xong.
- File nào đã thay đổi.
- Logic nào đã hoàn thiện.

## Chưa hoàn thành
- Những phần còn thiếu.
- Những phần đang pending.
- Những phần cần xác nhận thêm.

## Rủi ro / vấn đề gặp phải
Phải ghi rõ:
- Nguyên nhân.
- Ảnh hưởng.
- Mức độ rủi ro.
- Khả năng gây lỗi.

Ví dụ:
- Dependency conflict.
- Thiếu API contract.
- Không đồng bộ schema.
- Race condition.
- Performance bottleneck.

## Đề xuất hướng xử lí
AI phải:
- Đưa ra hướng xử lí rõ ràng.
- Giải thích ưu/nhược điểm nếu có nhiều lựa chọn.
- Ưu tiên giải pháp an toàn và maintainable.

---

# 4. Quy tắc minh bạch lỗi

Nếu gặp lỗi hoặc bất thường:
- Phải báo ngay lập tức.
- Không được tự giả định là “đã hoạt động”.
- Không được fake kết quả.
- Không được bỏ qua warning/error quan trọng.

Bắt buộc:
- Log rõ nguyên nhân.
- Chỉ ra vị trí lỗi.
- Đề xuất cách debug/fix.

---

# 5. Quy tắc giao tiếp

AI phải:
- Trả lời ngắn gọn, rõ ràng.
- Không spam.
- Không dùng icon/emojis vô nghĩa.
- Không dùng wording mơ hồ.
- Không vòng vo.

Không được:
- Tự bịa thông tin.
- Giả định requirement chưa tồn tại.
- Khẳng định khi chưa verify.

Nếu chưa chắc:
- Phải ghi rõ:
  - "Chưa xác minh"
  - "Cần kiểm tra thêm"
  - "Thiếu thông tin đầu vào"

---

# 6. Quy tắc cập nhật thay đổi

Khi có thay đổi:
- Phải cập nhật vào `SPIKE_REPORT.md`

Bao gồm:
- Thay đổi gì.
- Lý do thay đổi.
- Ảnh hưởng.
- Risk liên quan.
- Trạng thái hiện tại.

---

# 7. Quy tắc coding

Code phải:
- Readable.
- Maintainable.
- Predictable.
- Có separation of concerns.
- Có error handling.
- Có logging phù hợp.
- Không duplicate logic.

Ưu tiên:
- Clean architecture.
- Reusable components.
- Type safety.
- Testability.

---

# 8. Quy tắc xác nhận hoàn thành

Chỉ được xem là hoàn thành khi:
- Build pass.
- Không có lỗi critical.
- Logic đúng theo requirement.
- Không vi phạm protocol.
- Đã update report/document liên quan.

---

# 9. Nguyên tắc cuối cùng

Nếu:
- Thiếu thông tin,
- Requirement mâu thuẫn,
- Có rủi ro cao,
- Hoặc có khả năng phá vỡ hệ thống,

=> Phải dừng và báo ngay thay vì tự xử lí.