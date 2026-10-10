# Contributing to Dustless

Cảm ơn bạn muốn đóng góp. Vài quy ước ngắn để mọi thứ nhất quán.

## Quy trình

1. **Fork** repo này về tài khoản của bạn
2. Tạo branch từ `main`: `git checkout -b my-change`
3. Commit và push branch của bạn
4. Mở **Pull Request** vào `main`

Không thể push thẳng lên `main` — nhánh này được bảo vệ. Mọi thay đổi đều cần ít nhất **1 approving review**.

## Quy tắc vàng

> **Không thêm rule dọn mới vào `rules.yaml` nếu bạn chưa viết phần kiểm chứng cho nó.**

Một rule xóa file mà không kiểm chứng mục đó còn ai dùng hay không là bug, không phải tính năng. Nếu rule không kiểm chứng được, hãy đặt nó ở `tier: yellow`.

Cụ thể:

- Xóa cache của tool version → phải quét chéo project thật
- Xóa `node_modules` → phải kiểm tra git có thay đổi chưa commit không
- Xóa thư mục người dùng tự tạo → `red`, không cho xóa

## Bối cảnh bắt buộc

Mọi rule phải kèm hai field: `path` có mặt định cho **cả ba nền tảng**, hoặc chỉ định rõ `mac` / `win` / `linux` khi path khác nhau. Rule chỉ chạy được trên một OS sẽ bị reject.

## Báo lỗi

Mở issue kèm:

- Phiên bản OS và hệ điều hành
- Output của `dustless scan`
- Bạn mong đợi Dustless làm gì

**Quan trọng:** trước khi báo, hãy chạy `dustless scan` và xác nhận hành vi có thực sự sai. Nếu rule chưa được hỗ trợ, đó là feature request chứ không phải bug.

## Code style

- TypeScript, không framework test
- Không dependency mới nếu chưa bàn bạc trong issue
- Test cho mọi logic kiểm chứng — đây là phần dễ sai nhất của dự án