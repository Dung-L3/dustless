# Dustless

[English](README.md) · [Tiếng Việt](README.vi.md) · [中文](README.zh.md)

**Dọn dung lượng ổ đĩa cho máy lập trình viên.** Nó đo mọi cache toolchain trong rule database, chứng minh mỗi mục đã không còn ai dùng bằng cách đọc project thật của bạn, rồi chỉ xóa những gì đã qua kiểm chứng.

Dustless là một binary đã compile, chạy trên macOS, Windows và Linux. Không cần runtime, không daemon, không quyền admin.

---

## Vấn đề

Trên máy lập trình viên, phần lớn dung lượng có thể thu hồi nằm ở cache toolchain — Gradle, npm, pnpm, bun, uv, pub-cache, Cargo, Go modules, ảnh Android SDK. Trình dọn dẹp phổ biến nhìn chỗ khác hẳn: `~/Library/Caches`, log hệ thống, `.DS_Store`, ứng dụng không dùng.

Đo trên máy tham chiếu (macOS, Bun 1.3.13, ngày 2026-10-11): `du -sh ~/Library/Caches` báo **228 MB** — và con số đó vẫn thấp hơn thực tế, vì nhiều thư mục con trả về `Operation not permitted` nếu thiếu Full Disk Access. Cùng khoảng thời gian đó, `dustless scan` báo **13.8 GB thu hồi được** chỉ từ cache toolchain (`Thu hồi được 13.8 GB`). Chênh lệch 60 lần giữa chỗ trình dọn nhìn vào và chỗ byte thật sự nằm — và những thư mục giữ hàng chục gigabyte chính là những chỗ một tool dọn dẹp tổng quát không dám đụng tới, vì nó không chứng minh được chúng đã không còn ai dùng.

## Khác biệt: quét chéo trước khi xóa

Dustless không xóa một cache chỉ vì nó nằm trong thư mục cache. Trước hết nó chứng minh không còn gì cần đến nó.

Lấy ví dụ Gradle. `~/.gradle/caches/8.12` và `~/.gradle/caches/8.14` giống nhau về cấu trúc. Không có gì trên đĩa nói cái nào đã chết. Cách duy nhất để biết là đọc từng project thật trên máy:

- Dò `~/Innotech`, `~/Personal`, `~/Developer`, `~/Projects`, `~/repos` cộng thêm hai cấp trong `$HOME` (`src/core/verify/gradle.ts:32`).
- Đọc `gradle-wrapper.properties`, `gradle.properties`, `build.gradle`, `build.gradle.kts` (`src/core/verify/gradle.ts:18`).
- Bóc `distributionUrl` ra `gradle-<version>-bin.zip` (`src/core/verify/gradle.ts:25`).
- Bỏ qua các bản vendored, để một file wrapper nằm sâu trong `build/`, `SourcePackages/`, `node_modules/`, `Pods/`, `DerivedData/` hoặc `.gradle/` không bao giờ bị tính là project thật (`src/core/verify/gradle.ts:6`).
- Nếu bất kỳ project nào vẫn ghim ở 8.12, cache đó được báo **BLOCKED** và nằm lại trên đĩa.

Lượt dò bị giới hạn bởi ngân sách 200,000 entry để không chạy vô tận (`src/core/verify/gradle.ts:27`). Cùng ý tưởng đó vận hành `git_clean` cho `node_modules`: một thao tác merge đang dở, một thay đổi chưa commit hoặc một commit chưa push đều làm thư mục đó không được xóa (`src/core/verify/git.ts:30`).

## Bốn mức an toàn

| Mức | Là gì | `apply` làm gì |
| --- | --- | --- |
| 🟢 **GREEN** | Cache thuần, tái tạo được. Kiểm chứng chéo — nếu rule yêu cầu — đã đạt. | Tự xóa sau bản tổng kết xác nhận |
| 🟡 **YELLOW** | Có thể vẫn đang dùng — VM disk, emulator AVD, build output. Cũng gồm mọi mục bị hạ cấp vì trượt một kiểm tra. | Hỏi từng mục, một mục một câu |
| ⛔ **BLOCKED** | Rule yêu cầu kiểm chứng và kiểm chứng thất bại. | **Không bao giờ xóa.** Không phải bởi `--yes`, không phải bởi bất kỳ cờ nào |
| 🔴 **RED** | Danh sách path được bảo vệ, viết cứng: Keychain, Mail, iCloud, `*-wal`/`*-shm`, `Preferences`, `.git`, Documents, Desktop, Pictures, Movies, Music, Contacts, Reminders, Calendar, Finance, Messages (`src/core/paths.ts:81`) | Không bao giờ thành một finding. Được kiểm tra lại ngay trước lúc xóa |

### Vì sao BLOCKED không thể bị ghi đè

Một phiên bản trước của tool này hạ một ca kiểm chứng thất bại xuống YELLOW. Một sự cố thật đã xảy ra: một lần chạy `--yes` đã xóa một Gradle cache mà một project đang hoạt động vẫn dùng, và khoảng 36 GB dữ liệu của người dùng đi cùng.

Nên hành vi được sửa từ gốc. Một finding có kiểm chứng thất bại sẽ bật cờ `blocked`, và cờ đó được kiểm tra ở bốn điểm độc lập — scan đánh dấu, phần tổng kết của apply loại ra, `apply()` kiểm tra lại, và safety layer của MCP từ chối cả lệnh. `--yes` bỏ qua câu hỏi. Nó không thể tạo ra một kiểm chứng đạt, và không thể gỡ cờ chặn.

RED cũng vậy: đó là một danh sách regex được biên dịch thẳng vào binary. Không cờ nào, không file rule nào, không tham số MCP nào chạm tới được nó.

## Cài đặt

### Binary từ release

Push một tag `v*` và workflow build sẽ compile bốn target rồi đính kèm chúng vào release: `dustless-macos` (Intel), `dustless-macos-arm64` (Apple Silicon), `dustless-windows.exe` và `dustless-linux`. Tải đúng bản cho máy bạn, đặt vào đâu đó trên `PATH`, xong.

```sh
dustless doctor     # xác nhận nó chạy và đọc được cache của bạn
```

`doctor` không cần Full Disk Access. Nó in nền tảng, thư mục config, số rule, tổng và dung lượng trống, cùng một bài kiểm tra khả năng đọc theo từng path.

### Từ source

Cần Bun 1.3 trở lên.

```sh
git clone https://github.com/Dung-L3/dustless
cd dustless
bun install
bun run build          # ghi ra dist/dustless
./dist/dustless scan
```

Bạn cũng có thể chạy thẳng entrypoint TypeScript, không cần build: `bun src/cli.ts scan`.

## Bắt đầu nhanh

Nếu bạn chưa từng dùng tool terminal, làm đúng những bước sau.

**Bước 1 — xem, không xóa gì.**

```sh
dustless scan
```

Output thật trên máy tham chiếu:

```
dustless scan — mac — 1351ms — còn trống 301.8 GB

🟢 GREEN    2.7 GB  0d  npm.cacache
    /Users/mac/.npm/_cacache
🟢 GREEN    2.6 GB  125d  pnpm.store
    /Users/mac/Library/pnpm/store
🟡 YELLOW    5.3 GB  0d  android.system_images
    /Users/mac/Library/Android/sdk/system-images
    mới 0.0 ngày, rule yêu cầu ≥ 90 ngày

🟢 4 mục 5.8 GB · 🟡 2 mục 8.0 GB · 🔴 danh sách đỏ đã chặn
Thu hồi được 13.8 GB
```

`scan` chỉ đọc. Nó không thể xóa gì, bất kể bạn truyền cờ nào.

**Bước 2 — xóa, sau bản tổng kết.**

```sh
dustless apply
```

Bạn sẽ thấy điều này trước khi có bất cứ thứ gì bị gỡ:

```
Sẽ xóa 4 mục tự động (5.8 GB)
Sẽ hỏi  2 mục (8.0 GB)
Tổng   13.8 GB

Xóa? [y/N]
```

Gõ `y` rồi Enter để tiếp tục. Bất kỳ ký tự nào khác — kể cả chỉ Enter — sẽ hủy và không xóa gì. Giao diện là tiếng Việt vì đó là thứ binary in ra, và vì vậy ở đây nó được giữ nguyên.

**Bước 3 — trả lời các mục vàng.** Với từng mục YELLOW bạn được hỏi riêng, từng mục một:

```
🟡 YELLOW xóa 5.3 GB ở /Users/mac/Library/Android/sdk/system-images? [y/N]
```

`y` xóa mục đó. Bất kỳ ký tự nào khác sẽ bỏ qua và sang mục tiếp theo. Không có gì được gộp chung sau lưng bạn.

## Tham chiếu CLI

Mọi lệnh dưới đây đều được implement trong `src/cli.ts`.

| Lệnh | Hành vi |
| --- | --- |
| `dustless scan` | Quét chéo mọi rule, in ra finding sắp theo kích thước, kèm tổng theo từng mức và số byte thu hồi được. Chỉ đọc. |
| `dustless ui` | Khởi động giao diện trình duyệt cục bộ trên 127.0.0.1 và mở nó. Xem [Web UI](#web-ui). |
| `dustless apply` | Scan, hiện bản tổng kết, hỏi `Xóa? [y/N]`, rồi xóa GREEN và hỏi từng mục YELLOW. Exit code `1` nếu có mục nào thất bại. |
| `dustless rule list` | In rule database kèm mức và mô tả, rồi ghi ra nguồn đã nạp. |
| `dustless rule show <id>` | In một rule dạng JSON. |
| `dustless rule add <id> <green\|yellow> <desc> <path> [path…]` | Nối thêm rule mới vào `~/.config/dustless/rules.yaml` với `paths.all`. |
| `dustless rule validate [file]` | Parse và validate một file rules. Bỏ trống đường dẫn để validate database đã gộp. |
| `dustless doctor` | Nền tảng, thư mục config, số rule, tổng/trống, khả năng đọc các path chính, kiểm tra Full Disk Access. |
| `dustless mcp` | Phục vụ MCP qua stdio cho AI agent. Xem [docs/MCP.md](docs/MCP.md). |
| `dustless version` | In `0.1.0`. `dustless help` in hướng dẫn dùng, và gõ `dustless` trần cũng in hướng dẫn. |

### Cờ

| Cờ | Tác dụng |
| --- | --- |
| `--json` | Output máy đọc ra stdout cho `scan`, `apply`, `rule list` và `doctor`. Đồng thời tắt câu hỏi tương tác. |
| `--quiet` | Tắt các dòng dành cho người đọc. |
| `--yes` | Bỏ qua bước xác nhận. Bỏ qua cả câu hỏi tổng kết **và** các câu hỏi từng mục YELLOW. Nó không bỏ qua kiểm chứng, và không gỡ được BLOCKED hay RED. |
| `--port <n>` | Chỉ dùng với `ui`. Cổng để listen. Phải nằm trong 1024-65535. Mặc định là `4173`. |
| `--no-open` | Chỉ dùng với `ui`. Khởi động server mà không mở trình duyệt. |
| `--help` | Hướng dẫn dùng. Chấp nhận kèm bất kỳ lệnh nào. |

## Web UI

`dustless ui` khởi động một server cục bộ và mở giao diện trong trình duyệt của bạn.

```sh
dustless ui                        # http://127.0.0.1:4173
dustless ui --port 8080            # tự chọn cổng khác
dustless ui --no-open              # chạy mà không mở trình duyệt
```

Nó chỉ bind **127.0.0.1** — không bao giờ `0.0.0.0`, không bao giờ một interface có thể định tuyến (`src/ui/server.ts:19`, `src/ui/server.ts:161`). Cổng ngoài khoảng 1024-65535 bị từ chối trước khi socket mở, và nếu cổng đã bị chiếm thì server thoát ra thay vì lặng lẽ nghe ở một chỗ khác.

Nó còn từ chối theo Host header. Một request có `Host` không phải `127.0.0.1` hoặc `localhost` sẽ nhận `403` trước khi routing chạy (`src/ui/server.ts:103`, `src/ui/server.ts:122`), và một CSP nghiêm ngặt `default-src 'none'; script-src 'self'` đi kèm mọi response (`src/ui/server.ts:24`).

Vì sao điều này quan trọng: tiến trình này có endpoint `POST /api/apply` xóa file trên đĩa của bạn. Bất cứ thứ gì tới được cổng đó cũng tới được endpoint xóa. Chỉ-loopback cộng với kiểm tra Host là thứ đứng giữa một DNS rebind lạc và một thư mục home bị xóa sạch.

Các route: `GET /api/scan`, `GET /api/rules`, `GET /api/space`, `POST /api/apply`. `Ctrl+C` (hoặc `SIGTERM`) dừng server.

## AI agent / MCP

`dustless mcp` nói chuyện MCP qua stdio. Tài liệu đầy đủ, cấu hình client cho Claude Code, opencode, Cursor và VS Code, cùng một hội thoại mẫu: **[docs/MCP.md](docs/MCP.md)**. Năm tool: `scan`, `apply`, `list_rules`, `free_space`, `doctor`.

Cổng chặn trong `apply` là phần đáng chú ý nhất. Không có `confirm: true` thì lệnh không xóa gì và trả về đúng kế hoạch đó (`src/mcp/safety.ts:43`). Thứ tự đúng luôn là: scan, cho người dùng thấy số byte, nhận một câu "yes" rõ ràng, rồi gửi lại y hệt lệnh đó kèm `confirm: true`.

Một agent không bao giờ được tự ý đặt `confirm: true`. Lập luận không phải là "xóa cái này có hợp lý không" — mà là "một con người, ngay lúc này, đã đọc đúng con số byte này và đã nói có". Nếu câu trả lời không phải một câu có đã được ghi nhận, lệnh đó là một lần chạy thử. Ngoài ra: RED từ chối cả lệnh, BLOCKED từ chối cả lệnh, một rule id lạ từ chối cả lệnh, và bất kỳ thứ gì vượt 50 GB đều từ chối trừ khi bạn truyền thêm `allow_large: true` (`src/mcp/safety.ts:7`). Apply là tất cả-hoặc-không — một vấn đề là không xóa gì cả.

## Rules

Database đi kèm là `src/core/default-rules.yaml`. Nó có sẵn 26 rule phủ Gradle, npm, pnpm, bun, uv, pub-cache, Homebrew, Yarn, pip, Go, Cargo, Brave, Chrome, Firefox, Edge, Puppeteer, Android, Colima, Docker và output `node_modules`/`build` của project.

Đặt một file ở `~/.config/dustless/rules.yaml` (hoặc `$XDG_CONFIG_HOME/dustless/rules.yaml`) và nó sẽ được gộp đè lên database đi kèm: một rule có `id` trùng **thay thế** rule gốc, còn id mới thì được **thêm vào** (`src/core/rules.ts:18`). Không có cách nào xóa hẳn một rule gốc — hãy thay nó bằng một rule không match gì cả nếu bạn muốn nó bất lực.

Một rule thật:

```yaml
- id: my.toolchain_cache
  tier: green
  desc: Cache của toolchain nội bộ, tự tải lại khi build
  paths:
    all: "~/.cache/mytool"
    win: "%LOCALAPPDATA%/mytool/cache"
  match: '^[0-9]+\.[0-9]+$'
  minAgeDays: 60
```

| Field | Ý nghĩa |
| --- | --- |
| `id` | Duy nhất. Thay thế rule gốc có cùng id. |
| `tier` | `green` hoặc `yellow`. Mọi giá trị khác bị từ chối lúc nạp (`src/core/rules.ts:56`). |
| `desc` | Một dòng, hiển thị trong `rule list`. |
| `paths` | Key là `mac`, `win`, `linux` hoặc `all` (`src/core/rules.ts:7`). `~` nở ra thành home directory; trên Windows `%VAR%` nở từ biến môi trường (`src/core/paths.ts:13`). Mỗi value là một string hoặc một list string. Dấu `*` nở ra thành các thư mục con trực tiếp. |
| `match` | Regex tuỳ chọn, so với basename của thư mục đang xét. |
| `minAgeDays` | Nếu file mới nhất bên trong còn trẻ hơn mốc này, finding bị hạ từ GREEN xuống YELLOW (`src/core/scan.ts:72`). |
| `requireVerify` | Tên một bài kiểm chứng chéo: `gradle_version_unused`, `git_clean`, hoặc `not_in_gitignore`. Nếu trượt, finding bị hạ xuống YELLOW **và** bị đánh BLOCKED (`src/core/scan.ts:76`). |

Theo CONTRIBUTING, một rule mới mà không có kiểm chứng là bug, không phải tính năng. Nếu không kiểm chứng được, hãy đánh dấu nó là `yellow`.

Hãy validate trước khi tin:

```sh
dustless rule validate
dustless rule list
```

## Xử lý sự cố

**macOS: thiếu kết quả hoặc `doctor` báo `EPERM`.**
TCC đang che các thư mục khỏi tiến trình. Cấp Full Disk Access trong System Settings › Privacy & Security › Full Disk Access, rồi đóng và mở lại terminal. `doctor` in ra chẩn đoán này và trả exit code khác 0 (`src/cli.ts:214`). Lưu ý cái bẫy: thiếu quyền làm cho `~/Library/Caches` trông *nhỏ hơn* thực tế, nên một số cache không bao giờ xuất hiện trong scan.

**Windows: `EBUSY` hoặc `EPERM` khi xóa.**
Antivirus và Windows Search indexer giữ khoá tạm thời. `remove()` thử lại tối đa 4 lần trên Windows với backoff luỹ thừa, rồi bỏ cuộc (`src/core/apply.ts:98`). Hãy tắt indexer hoặc loại trừ thư mục đó, rồi chạy lại.

**Không có gì bị xóa.** Đọc cột `detail`. Các nguyên nhân thường gặp, theo đúng thứ tự bạn sẽ gặp:
- Rule chưa đạt `minAgeDays`. Một ảnh Android system image 3 ngày tuổi với `minAgeDays: 90` là YELLOW theo thiết kế, không phải lỗi.
- Tool đang chạy. Nếu `npm`, `npx`, `pnpm` hoặc `yarn` xuất hiện trong bảng tiến trình, cache của nó bị bỏ qua để không phá một lượt cài đặt đang chạy (`src/core/apply.ts:9`).
- Kiểm chứng thất bại. Mục đó là BLOCKED và `--yes` không đổi được.
- Path trúng danh sách đỏ, là `$HOME` hoặc thư mục cha của nó, hoặc là filesystem root (`src/core/apply.ts:86`).

**`apply` thoát ngay lập tức.** Nếu stdout không phải TTY — một CI job, một pipe, một wrapper script — `apply` từ chối hỏi và không xóa gì (`src/cli.ts:130`). Hãy chạy trong terminal thật. Khi tự động hoá, hãy dùng MCP server, vì nó có cổng xác nhận tường minh riêng.

**Một rule tôi viết cứ ở YELLOW.** Hoặc `minAgeDays` chưa đạt, hoặc `requireVerify` đang trượt. `scan` in lý do ở cột `note`, ngay dưới path. Hãy sửa nguyên nhân gốc — một thay đổi chưa commit, một phiên bản tool mà project vẫn còn ghim — rồi scan lại.

## Đóng góp

Xem [CONTRIBUTING.md](CONTRIBUTING.md). `main` được bảo vệ, kể cả với chính chủ repo. Fork, tạo branch, commit, mở pull request. Không thể push thẳng.

Luật vàng: **không thêm rule dọn dẹp vào rule database nếu chưa viết phần kiểm chứng chứng minh nó an toàn.** Một rule xóa file mà không kiểm tra xem còn ai cần đến chúng là bug, không phải tính năng.

Trước khi mở PR: `bun run typecheck`, rồi `bun test`, rồi `bun run build`.

## Giấy phép

MIT