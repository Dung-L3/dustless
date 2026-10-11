# Contributing to Dustless

Cảm ơn bạn muốn đóng góp. Vài quy ước ngắn để mọi thứ nhất quán.

## Quy trình

1. **Fork** repo này về tài khoản của bạn
2. Tạo branch từ `main`: `git checkout -b my-change`
3. Commit và push branch của bạn
4. Mở **Pull Request** vào `main`

Không thể push thẳng lên `main` — nhánh này được bảo vệ và áp dụng cả cho admin. Cấu hình branch protection hiện tại: status check `verify` bắt buộc (CI chạy `bun run typecheck`, `bun test`, `bun run build` và smoke test binary), `@Dung-L3` là code owner của mọi thay đổi, lịch sử phải tuyến tính, và không cho force push cũng không cho xoá branch. Trước khi mở PR, hãy chạy đúng ba lệnh đó ở local — nó là job `verify` của CI.

### Vì sao không có yêu cầu review bắt buộc

Cấu hình ban đầu của repo yêu cầu 1 approving review. Điều đó **không thể hoạt động** trên repo cá nhân của một người duy nhất: GitHub không bao giờ cho phép bạn duyệt PR do chính bạn tạo, kể cả khi bạn là owner và admin. Kết quả là `main` bị khoá vĩnh viễn — không ai merge được, kể cả chủ repo.

Vì vậy `required_approving_review_count` được đặt là `0`, còn `require_code_owner_reviews` vẫn bật. PR vẫn bắt buộc, ai cũng không thể push thẳng, nhưng maintainer không bị chặn bởi một quy tắc không thể thỏa mãn.

Khi repo có thêm 2 người đóng góp, hãy bật lại yêu cầu review:

```bash
gh api -X PUT repos/Dung-L3/dustless/branches/main/protection \
  -f required_approving_review_count=1
```

## Quy tắc vàng

> **Không thêm rule dọn mới vào `rules.yaml` nếu bạn chưa viết phần kiểm chứng cho nó.**

Một rule xóa file mà không kiểm chứng mục đó còn ai dùng hay không là bug, không phải tính năng. Nếu rule không kiểm chứng được, hãy đặt nó ở `tier: yellow`.

Cụ thể:

- Xóa cache của tool version → phải quét chéo project thật
- Xóa `node_modules` → phải kiểm tra git có thay đổi chưa commit không
- Xóa thư mục dữ liệu người dùng → **không viết rule cho nó**. Đó là job của danh sách đỏ ở `src/core/paths.ts:81`, không phải của rule database

Cái điểm mấu chốt: `requireVerify` trượt thì finding đó bị gắn cờ `blocked` và không bao giờ bị xóa, kể cả dưới `--yes` (`src/core/scan.ts:76`, `src/core/apply.ts:60`). Một rule `green` không có `requireVerify` sẽ xóa thẳng — đó là trường hợp nguy hiểm nhất trong toàn bộ hệ thống, hãy viết kiểm chứng.

## Bối cảnh bắt buộc

Mọi rule phải khai báo `paths`, và key chỉ được là `mac`, `win`, `linux` hoặc `all` (`src/core/rules.ts:7`). Bộ nạp sẽ **từ chối** file nếu thiếu `id`, thiếu `desc`, thiếu `paths`, có key platform lạ, có value rỗng, hoặc đặt `tier` ngoài `green|yellow` (`src/core/rules.ts:53`). Nó **không** đòi bạn phải phủ cả ba nền tảng: một rule chỉ có `mac` vẫn hợp lệ, và chỉ chạy trên nền tảng đó.

Nếu một rule chỉ nên chạy ở một OS, hãy nói rõ bằng cách chỉ liệt kê key của OS đó — đừng viết path của OS khác rồi hy vọng nó không tồn tại.

## Test

Đọc [docs/TESTING.md](docs/TESTING.md) trước khi viết test. Điểm không được bỏ qua:

- **Không bao giờ chạy `apply` trong một process đã resolve home.** `os.homedir()` không đọc lại `$HOME` sau khi process khởi động, và `src/core/paths.ts` capture `HOME` một lần lúc module load. Mọi test xóa file phải chạy trong **child process** với `HOME` trỏ vào thư mục tạm. Đây không phải cảnh báo lý thuyết: sửa sai chỗ này đã xoá nhầm dữ liệu thật hai lần.
- **Không thêm test chạy trình duyệt.** Một Chromium-family với `--user-data-dir` mới sẽ làm macOS hỏi keychain ở profile thật của bạn. Lý do đầy đủ ở docs/TESTING.md.
- Đừng nới lỏng assertion để làm test xanh. Một check đỏ là một phát hiện về sản phẩm, và nó được ghi lại ở `tests/e2e-ui/REPORT.md`.

## Báo lỗi

Mở issue kèm:

- Phiên bản OS và hệ điều hành
- Output của `dustless scan`
- Bạn mong đợi Dustless làm gì

**Quan trọng:** trước khi báo, hãy chạy `dustless scan` và xác nhận hành vi có thực sự sai. Nếu rule chưa được hỗ trợ, đó là feature request chứ không phải bug.

## Code style

- TypeScript, `bun:test` — không thêm test framework, không thêm dependency
- Không dependency mới nếu chưa bàn bạc trong issue
- Test cho mọi logic kiểm chứng — đây là phần dễ sai nhất của dự án
- Comment giải thích *tại sao*, không phải *là gì*
