# Kế hoạch & Nhiệm vụ của Kiệt (Android Daemon Lead) - Dự án Rift v0.1

Bảng dưới đây liệt kê toàn bộ các nhiệm vụ (GitHub issues) được giao cho Kiệt trải dài trong suốt 12 tuần, kèm theo sự phụ thuộc (cần chờ ai) để dễ dàng quản lý tiến độ.

## Bảng Nhiệm vụ Chi Tiết

| Tuần | Nhiệm vụ của Kiệt (Tên Issue) | Cần chờ / Phối hợp với ai? (Dependencies) |
| :--- | :--- | :--- |
| **Week 1** | - `[infra] Dart daemon skeleton with PointyCastle smoke test`<br>- `[risk-asn1-parser] Spike: verify PointyCastle can build ECDSA P-256 cert` | 🟢 **Không chờ ai.** Tự làm độc lập. *(Đã hoàn thành)* |
| **Week 2** | - `Module interfaces matching C# shape`<br>- `[risk-cert-interop] Generate ECDSA cert with custom ext...`<br>- `[test] Unit test skeleton with first crypto tests` | 🟡 **Chờ Thạo:** Để thống nhất thiết kế Interface cho cả C# và Dart.<br>🟡 **Chờ Biên:** Biên phải tung ra bộ "Test vectors" (dữ liệu mẫu) thì Kiệt mới có cái để verify (xác minh) code của mình chạy đúng chuẩn hay không. |
| **Week 3** | - `Ed25519 identity generation and storage`<br>- `ECDSA P-256 self-signed certificate generation with custom extension`<br>- `Frame encoder/decoder`<br>- `[risk-asn1-parser] Custom X.509 ASN.1 parser v1` | 🟡 **Chờ Biên:** Phải có bản nháp đặc tả (Spec) Section 5 để biết cấu trúc Frame.<br>🔴 **Chú ý:** Cái `Custom X.509 ASN.1 parser v1` là việc khó nhất dự án. |
| **Week 4** | - `mDNS via nsd package (advertise + browse)`<br>- `TLS 1.3 via SecureSocket`<br>- `Post-handshake Ed25519 extraction via custom ASN.1 parser`<br>- `session.hello/accept/reject implementation`<br>- `Android foreground service hosting daemon isolate` | 🟡 **Chờ Biên:** Đợi Biên ra Spec Section 4 và session test vectors.<br>🤝 **Phối hợp Thạo:** Phải gọi qua lại giữa máy Windows (Thạo) và Android (Kiệt) để test thử mTLS và Session có bắt tay nhau thành công không. |
| **Week 5** | - `sqflite trust store with five states`<br>- `Pairing state machine`<br>- `Persistent identity recovery on foreground service restart` | 🟡 **Chờ Biên:** Chốt Spec Section 6 (Trust state machine).<br>🤝 **Phối hợp Thạo:** Test ghép nối (Pairing) 2 chiều (Win -> And, And -> Win). |
| **Week 6** | - `Capability advertise/select`<br>- `Presence heartbeat publisher and reachability tracker`<br>- `Battery impact check for continuous heartbeats` | 🟡 **Chờ Biên:** Chờ tài liệu Spec Section 7 & 10. |
| **Week 7** | - `Clipboard offer/fetch service`<br>- `Android clipboard integration via Kotlin platform channel` | 🟡 **Chờ Biên:** Chờ Spec Section 9 (Clipboard).<br>🤝 **Phối hợp Kim:** Cùng Kim móc nối (integrate) phần code Kotlin vào Flutter app. |
| **Week 8** | - `Operation manager with state machine`<br>- `Standard error mapping and recovery` | 🟡 **Chờ Biên:** Chờ Spec Section 8 (Operation lifecycle). |
| **Week 9** | - `[risk-asn1-parser] ASN.1 parser fuzz harness and corpus`<br>- `trust.revoke implementation with session termination`<br>- `Durable negative-trust persistence` | 🤝 **Phối hợp Biên:** Cùng Biên viết các bài test đập phá (fuzz testing) để thử làm sập cái ASN.1 parser. |
| **Week 10** | - `[bug] Triage and fix all P0/P1 Android defects` | 🟡 **Chờ Kim:** Kim đi test, bấm bậy bạ để tìm lỗi (bug) rồi Kiệt vào fix. |
| **Week 11** | - `[docs] Android installation guide` (Viết hướng dẫn cài đặt) | 🟢 **Không chờ ai.** |
| **Week 12** | - Ổn định Android daemon, xuất file APK cuối cùng. | 🟢 **Không chờ ai.** |

---

## 💡 Lời khuyên & Lưu ý quan trọng
Nhìn vào bảng trên, có thể thấy **rất nhiều đầu việc phụ thuộc vào Biên (người viết Spec và làm Test Vectors)**. 

**Nguyên tắc làm việc (quy định ở mục 5 - Risk Register):**
Không bao giờ được tự ý code mò khi Biên chưa ra "Test Vectors" (dữ liệu mẫu đối chiếu). Nếu Biên chậm trễ, Kiệt phải hối thúc Biên ngay lập tức để tránh làm nghẽn tiến độ của mình, đặc biệt là trong **Tuần 2** và **Tuần 3**.
