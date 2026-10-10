# Dustless

> Cache dọn sạch trên máy dev. Không đụng vào dữ liệu của bạn.

Dustless là công cụ dọn dẹp dung lượng ổ đĩa, thiết kế riêng cho **máy lập trình viên** — nơi phần lớn dung lượng nằm ở cache của toolchain (Gradle, npm, pnpm, bun, uv, pub-cache), chứ không phải ở rác hệ thống thông thường.

Hỗ trợ **macOS, Windows, Linux**.

## Vấn đề

Các trình dọn dẹp phổ biến quét `~/Library/Caches`, log hệ thống, file `.DS_Store`, ứng dụng không dùng. Trên một máy dev, những chỗ đó gần như trống — phần lớn cache ở đó còn đang cần.

Kết quả: tool chạy xong, thu hồi được vài chục MB, còn hàng chục GB nằm im trong `.gradle`, `~/.npm`, `~/.android` — nơi tool không dám đụng tới.

Dustless giải quyết đúng phần bị bỏ qua đó, với nguyên tắc **không quét chéo thì không xóa**.

## Nguyên tắc thiết kế

### 1. Quét chéo, không xóa mù

Dustless không xóa cache chỉ vì nó nằm trong thư mục cache. Trước khi xóa, nó **kiểm chứng** mục đó có thật sự không còn ai dùng:

- `~/.gradle/caches/8.12/` chỉ bị xóa sau khi Dustless đọc `gradle-wrapper.properties` của mọi project thật và xác nhận không project nào dùng Gradle 8.12.
- `node_modules/` bị giữ nguyên nếu project còn thay đổi chưa commit.

Quét hụt một project → xóa nhầm cache đang chạy → build hỏng giữa chừng. Đây là lỗi nguy hiểm nhất của mọi công cụ dọn cache, và là lý do phần lớn chúng dừng lại ở mức an toàn.

### 2. Ba tầng an toàn

| Tầm | Ý nghĩa | Hành động mặc định |
|---|---|---|
| 🟢 **GREEN** | Cache thuần, tái tạo được | Xóa tự động |
| 🟡 **YELLOW** | Cần bạn quyết định (VM, ảnh emulator, build output) | Hỏi từng mục |
| 🔴 **RED** | Dữ liệu thật — Keychain, Mail, iCloud, SQLite WAL | Chặn cứng |

Nếu một rule **không kiểm chứng được**, nó bị hạ từ GREEN xuống YELLOW. Có thể mất công dọn, nhưng không bao giờ xóa nhầm.

### 3. Mặc định là an toàn

Không có path nào bị động tới nếu không khớp rule nào. Danh sách RED được tích hợp sẵn và không tắt được. Lệnh xóa luôn mặc định là `--dry-run`.

## Cách dùng

```bash
dustless scan              # chỉ xem — không xóa gì
dustless apply             # GREEN tự xóa, YELLOW hỏi từng cái
dustless ui                # mở giao diện web cục bộ
```

## Tương lai

- Quét chéo project (Gradle wrapper, git status, lockfile)
- Quarantine + tự hết hạn
- Giao diện web nội bộ
- Menu bar cho macOS

## Đóng góp

Xem [CONTRIBUTING.md](CONTRIBUTING.md). Mọi thay đổi đi qua Pull Request và cần ít nhất 1 review.

## Giấy phép

MIT