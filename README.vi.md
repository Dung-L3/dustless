# Dustless

[English](README.md) · [Tiếng Việt](README.vi.md) · [中文](README.zh.md)

**Dọn dung lượng ổ đĩa cho máy lập trình viên.** Nó đo mọi cache toolchain trong rule database, chứng minh mỗi mục đã không còn ai dùng bằng cách đọc project thật của bạn, rồi chỉ xóa những gì đã qua kiểm chứng.

Dustless là một binary đã compile, chạy trên macOS, Windows và Linux. Không cần runtime, không daemon, không quyền admin. Phiên bản, 0.5.0, được đọc từ `package.json` lúc build (`src/cli/context.ts`) — một con số, một nguồn.

---

## Vấn đề

Trên máy lập trình viên, phần lớn dung lượng có thể thu hồi nằm ở cache toolchain — Gradle, npm, pnpm, bun, uv, pub-cache, Cargo, Go modules, ảnh Android SDK. Trình dọn dẹp phổ biến nhìn chỗ khác hẳn: `~/Library/Caches`, log hệ thống, `.DS_Store`, ứng dụng không dùng.

Đo trên máy tham chiếu (macOS, Bun 1.3.13, ngày 2026-10-11): `du -sh ~/Library/Caches` báo **213M** — và con số đó vẫn thấp hơn thực tế, vì nhiều thư mục con trả về `Operation not permitted` nếu thiếu Full Disk Access. Cùng ngày đó, `dustless scan` báo **3.4 GB thu hồi được** chỉ từ cache toolchain (`Thu hồi được 3.4 GB`). Chênh lệch 16 lần giữa chỗ trình dọn nhìn vào và chỗ byte thật sự nằm — và những thư mục giữ hàng gigabyte chính là những chỗ một tool dọn dẹp tổng quát không dám đụng tới, vì nó không chứng minh được chúng đã không còn ai dùng. Cả hai con số đều thay đổi theo cache của bạn; đây là ảnh chụp của một máy trong một ngày, không phải benchmark.

## Khác biệt: quét chéo trước khi xóa

Dustless không xóa một cache chỉ vì nó nằm trong thư mục cache. Trước hết nó chứng minh không còn gì cần đến nó.

Lấy ví dụ Gradle. `~/.gradle/caches/8.12` và `~/.gradle/caches/8.14` giống nhau về cấu trúc. Không có gì trên đĩa nói cái nào đã chết. Cách duy nhất để biết là đọc từng project thật trên máy:

- Dò `$HOME` tối đa 5 cấp, bỏ qua thư mục ẩn và một danh sách bỏ qua cố định, và dừng ở thư mục đầu tiên trông như một project: `.git`, `package.json`, `pubspec.yaml`, `gradlew`, `settings.gradle` hoặc `settings.gradle.kts` (`src/core/verify/gradle.ts:31`, `src/core/verify/gradle.ts:61`).
- Từ mỗi gốc project, dò thêm tối đa 12 cấp và đọc `gradle-wrapper.properties`, `gradle.properties`, `build.gradle`, `build.gradle.kts` (`src/core/verify/gradle.ts:18`).
- Bóc phiên bản ra từ `distributionUrl` — `gradle-<version>-bin.zip` hoặc `-all.zip` (`src/core/verify/gradle.ts:25`).
- Bỏ qua các bản vendored — `build/`, `SourcePackages/`, `.dartServer/`, `node_modules/`, `.gradle/`, `.pub-cache/`, `DerivedData/`, `Pods/`, `ephemeral` — để một file wrapper nằm sâu trong đó không bao giờ bị tính là project thật (`src/core/verify/gradle.ts:6`).
- Nếu bất kỳ project nào vẫn ghim ở 8.12, cache đó được báo **BLOCKED** và nằm lại trên đĩa.

Lượt dò bị giới hạn: 12 cấp và tổng cộng 200.000 entry thư mục, nên không thể chạy vô tận (`src/core/verify/gradle.ts:27`). Cùng ý tưởng đó vận hành `git_clean` cho `node_modules`: một thao tác đang dở (`MERGE_HEAD`, `CHERRY_PICK_HEAD`, `rebase-merge`, …), một thay đổi chưa commit hoặc một commit chưa push đều làm thư mục đó không được xóa (`src/core/verify/git.ts:11`, `src/core/verify/git.ts:30`).

## Bốn mức an toàn

| Mức | Là gì | `apply` làm gì |
| --- | --- | --- |
| 🟢 **GREEN** | Cache thuần, tái tạo được. Kiểm chứng chéo — nếu rule yêu cầu — đã đạt. | Tự xóa, sau khi bạn xác nhận bản tổng kết |
| 🟡 **YELLOW** | Có thể vẫn đang dùng — VM disk, emulator AVD, build output — hoặc rule bị hạ vì chưa đạt `minAgeDays` (`src/core/scan.ts:132`). | Hỏi từng mục, một mục một câu |
| ⛔ **BLOCKED** | Rule yêu cầu kiểm chứng và kiểm chứng thất bại (`src/core/scan.ts:136`). Được ghi vào `totals.blocked` và không tính vào `reclaimable` (`src/core/scan.ts:200`). | **Không bao giờ xóa.** Không phải bởi `--yes`, không phải bởi bất kỳ cờ nào |
| 🔴 **RED** | Danh sách path được bảo vệ, viết cứng: Keychain, Mail, iCloud, `*-wal`/`*-shm`, `Preferences`, `.git`, Documents, Desktop, Pictures, Movies, Music, Contacts, Reminders, Calendar, Finance, Passes, Keynotes, Messages, `Application Support/com.apple.{Photos,MobileSync,Notes,Trial}` (`src/core/paths.ts:97`) | Không bao giờ thành một finding (`src/core/scan.ts:87`). Được kiểm tra lại trên đường dẫn thực ngay trước lúc xóa (`src/core/paths.ts:167`) |

BLOCKED không phải là một RED nhẹ hơn. RED là danh sách path tĩnh, không gì xóa được. BLOCKED là một kết luận sống: Dustless thử chứng minh cache đã không ai dùng và không chứng minh được.

### `apply` fail-closed

Mọi lần xóa đều được gắn với một rule id, và một key không có mặt sẽ phân giải thành `skip` (`src/core/apply.ts:84`):

```ts
const chosen = Boolean(opts.tiers && Object.hasOwn(opts.tiers, finding.ruleId));
const requested = chosen ? opts.tiers?.[finding.ruleId] ?? "skip" : "skip";
```

Một id gõ sai, một id mà payload quên mất, một rule mà scan không sinh ra — tất cả đều phân giải thành skip, không bao giờ thành tier của chính rule đó. Phiên bản trước mặc định thành tier của rule, nên một key bị bỏ sót lặng lẽ có nghĩa là "xóa"; đó là thứ đã lấy mất khoảng 36 GB trên một máy thật.

Mặc định đó là lưới an toàn cuối, không phải cơ chế. Mọi caller đều tự dựng map của riêng mình: CLI dựng từ scan đang chạy (`src/cli/scan.ts`), MCP dựng từ các rule id nó đã kiểm chứng trước (`src/mcp/tools.ts:189`).

### Vì sao BLOCKED không thể bị ghi đè

Cờ chặn được kiểm tra ở bốn điểm độc lập: scan bật cờ, phần tổng kết của apply loại những finding đó ra khỏi tập cần xóa (`src/cli/scan.ts`), `apply()` kiểm tra lại trước khi chạm vào filesystem (`src/core/apply.ts:63`), và safety layer của MCP từ chối cả lệnh (`src/mcp/safety.ts:98`). `--yes` bỏ qua câu hỏi. Nó không thể tạo ra một kiểm chứng đạt, và không thể gỡ cờ chặn. RED cũng vậy: đó là một danh sách regex được biên dịch thẳng vào binary. Không cờ nào, không file rule nào, không tham số MCP nào chạm tới được nó.

## Cài đặt

### Binary từ release

Push một tag `v*` và workflow build sẽ compile bốn target rồi đính kèm chúng vào release: `dustless-macos-arm64`, `dustless-macos-x64`, `dustless-linux-x64`, `dustless-windows-x64.exe` (`.github/workflows/release.yml:20-32`). Tải đúng bản cho máy bạn, đặt vào đâu đó trên `PATH`, xong. Windows còn có thêm `Dustless-<version>-setup.exe`, bản cài đặt theo từng người dùng, được CI cài rồi gỡ im lặng trước khi đính kèm.

```sh
dustless doctor     # xác nhận nó chạy và đọc được cache của bạn
```

`doctor` in ra nền tảng, home directory của bạn, thư mục config, số rule, tổng và dung lượng trống, cùng một bài kiểm tra khả năng đọc theo từng path. Nó trả exit code khác 0 khi một path nó cần không đọc được (`src/cli/doctor.ts`).

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
dustless scan — mac — 746ms — còn trống 308.5 GB

🟡 YELLOW    2.8 GB  0d  android.ndk
    /Users/mac/Library/Android/sdk/ndk
    mới 0.0 ngày, rule yêu cầu ≥ 90 ngày
🟢 GREEN  479.5 MB  0d  go.modcache
    /Users/mac/go/pkg/mod
🟢 GREEN  122.2 MB  0d  pubcache.hosted
    /Users/mac/.pub-cache/hosted
🟡 YELLOW   52.3 MB  0d  project.node_modules
    /Users/mac/.opencode/node_modules
    mới 0.0 ngày, rule yêu cầu ≥ 30 ngày
🟢 GREEN    9.7 MB  0d  npm.cacache
    /Users/mac/.npm/_cacache
🟡 YELLOW     150 B  0d  android.system_images
    /Users/mac/Library/Android/sdk/system-images
    mới 0.0 ngày, rule yêu cầu ≥ 90 ngày

🟢 3 mục 611.4 MB · 🟡 3 mục 2.8 GB · 🔴 danh sách đỏ đã chặn
Thu hồi được 3.4 GB
```

`scan` chỉ đọc. Nó không thể xóa gì, bất kể bạn truyền cờ nào.

**Bước 2 — xóa, sau bản tổng kết.**

```sh
dustless apply
```

Bạn sẽ thấy điều này trước khi có bất cứ thứ gì bị gỡ — kể cả trước mục GREEN đầu tiên:

```
Sẽ xóa 3 mục tự động (611.4 MB)
Sẽ hỏi  3 mục (2.8 GB)
Tổng   3.4 GB
Xóa? [y/N]
```

Gõ `y` rồi Enter để tiếp tục. Bất kỳ ký tự nào khác — kể cả chỉ Enter — sẽ hủy và không xóa gì. Nếu có finding bị chặn, bản tổng kết còn nói rõ có bao nhiêu mục không bao giờ xóa được, bạn trả lời thế nào cũng vậy (`src/cli/scan.ts`). Giao diện là tiếng Việt vì đó là thứ binary in ra, và vì vậy ở đây nó được giữ nguyên.

**Bước 3 — trả lời các mục vàng.** Với từng mục YELLOW bạn được hỏi riêng, từng mục một:

```
🟡 YELLOW xóa 2.8 GB ở /Users/mac/Library/Android/sdk/ndk? [y/N]
```

`y` xóa mục đó. Bất kỳ ký tự nào khác sẽ bỏ qua và sang mục tiếp theo. Không có gì được gộp chung sau lưng bạn.

## Full Disk Access và các rule không quét được

macOS TCC ẩn một số thư mục khỏi mọi tiến trình không có Full Disk Access, và nó ẩn bằng cách khiến chúng trông rỗng hoặc không tồn tại thay vì nêu tên thư mục cha bị bảo vệ. `dustless doctor` kiểm tra `~/Library/Mail` đúng vì lý do đó (`src/cli/doctor.ts`, `runDoctor`) và **thoát với mã 1 khi phép thử trả về `EPERM` hoặc `EACCES`**. Đó là thiết kế, không phải crash: một môi trường không đọc được cache của chính nó thì không thể được tin để báo cáo những gì bên trong, nên exit status nói lên điều đó. Đây cũng là lý do một lần scan có thể tìm thấy ít rule hơn database: rule nào có toàn bộ path không đọc được thì không đóng góp gì.

Một lần scan giờ nói rõ nó không nhìn được gì thay vì im lặng. `scan --json` mang thêm hai key bên cạnh `findings` và `totals` (`src/types.ts`, `ScanReport`):

- `unscannable` — một entry cho mỗi rule không tạo ra path nào quét được, gồm `ruleId`, `tier`, `desc`, các `pathPatterns` thất bại, và `reason` là `absent` (path không tồn tại), `no_access` (EACCES/EPERM — thường do thiếu Full Disk Access), `not_supported` (rule không có path cho nền tảng này), `red` (path trúng danh sách chặn vĩnh viễn) hoặc `error` (`src/core/scan.ts`, `scan`).
- `unscannableSummary` — số lượng theo từng reason, với cả năm key luôn có mặt.

Những rule đó bị loại khỏi `totals`, `reclaimable` và `freed`: field này chỉ có thể thêm thông tin, không bao giờ thêm một con số. Ứng dụng macOS mô hình hóa cả hai field và bản địa hóa cách diễn đạt reason (`UnscannableRule`, `UnscannableSummary` và `UnscannableText` trong `apps/dustless-mac/Sources/DustlessKit/Model/Reports.swift`).

## Tham chiếu CLI

Mọi lệnh dưới đây đều được implement trong `src/cli.ts`.

| Lệnh | Hành vi |
| --- | --- |
| `dustless scan` | Quét chéo mọi rule, in ra finding sắp theo kích thước, kèm tổng theo từng mức và số byte thu hồi được. Chỉ đọc. |
| `dustless apply` | Scan, in bản tổng kết, hỏi `Xóa? [y/N]`, rồi xóa GREEN và hỏi từng mục YELLOW. Exit code `1` nếu có mục nào thất bại. Với `--only-file <selection.json>` nó chỉ xóa đúng các path trong mảng đó. |
| `dustless rule list` | In rule database kèm mức và mô tả, rồi ghi ra nguồn đã nạp. |
| `dustless rule show <id>` | In một rule dạng JSON. |
| `dustless rule add <id> <green\|yellow> <desc> <path> [path…]` | Nối thêm rule mới vào `~/.config/dustless/rules.yaml` với `paths.all`. |
| `dustless rule validate [file]` | Parse và validate một file rules. Bỏ trống đường dẫn để validate database đã gộp. |
| `dustless doctor` | Nền tảng, home, thư mục config, số rule, tổng/trống, khả năng đọc các path chính, kiểm tra Full Disk Access. |
| `dustless mcp` | Phục vụ MCP qua stdio cho AI agent. Xem [docs/MCP.md](docs/MCP.md). |
| `dustless version` | In `0.5.0`. `dustless help`, và gõ `dustless` trần, in hướng dẫn dùng. |

### Cờ

| Cờ | Tác dụng |
| --- | --- |
| `--json` | Một đối tượng JSON duy nhất trên stdout cho `scan`, `apply`, `rule list`, `doctor`, `version`. Với `apply` nó còn hủy luôn: không có `--yes` thì không có câu hỏi, nên không xóa gì (`src/cli/scan.ts`). |
| `--quiet` | Tắt các dòng dành cho người đọc. |
| `--yes` | Bỏ qua bước xác nhận. Bỏ qua cả câu hỏi tổng kết **và** các câu hỏi từng mục YELLOW. Nó không bỏ qua kiểm chứng, và không gỡ được BLOCKED hay RED. |
| `--only-file <selection.json>` | Chỉ áp dụng đúng các path trong mảng JSON các đường dẫn tuyệt đối này; mọi finding khác thành `skipped` với lý do không được chọn. Bỏ qua cờ này thì `apply` giữ nguyên hành vi cũ. File không đọc được, hoặc không phải mảng string, thoát `1` và không xóa gì. |
| `--help` | Hướng dẫn dùng, in ra bất cứ khi nào nó xuất hiện — `dustless scan --help` in hướng dẫn, không chạy scan. `dustless` trần hoặc `dustless help` in ra y hệt. |

### `apply --json`

`apply --json` in đúng một đối tượng JSON trên stdout, ở mọi đường đi tới được nó — đã xóa, không có gì để xóa, đã hủy — với các key `outcomes`, `freed`, `freeBefore`, `freeAfter`, `elapsedMs` (`src/types.ts:72`). `freed` là `max(0, freeAfter - freeBefore)`: chênh lệch dung lượng trống của cả volume, không phải tổng số byte của các mục đã xóa, nên nó có thể báo `0` sau một lần xóa thật nếu giữa lúc đó có thứ khác lấp đĩa (`src/core/apply.ts:35`).

### Lỗi

Mọi lỗi tham số hoặc validation — lệnh lạ, cờ thiếu giá trị, file rules không parse được, `--only-file` không dùng được — đều có một dạng và một exit status:

| | stdout | stderr | exit |
| --- | --- | --- | --- |
| có `--json` | một đối tượng JSON, `{"error":"…"}` | trống | `1` |
| không có `--json` | trống | `✖ …` | `1` |

`--quiet` không bao giờ giấu lỗi: nó chỉ giảm các dòng kết quả cho người đọc, không giấu lý do một lệnh thoát khác 0. Giá trị nào thiếu là thiếu, không bao giờ lấy cờ kế tiếp: `dustless apps --uninstall --confirm` là lỗi usage về `--uninstall`, không phải yêu cầu gỡ một app tên `--confirm`.

## macOS app

`apps/dustless-mac` là ứng dụng SwiftUI native nhúng engine Dustless. Chạy trên macOS 14+ như một ứng dụng bình thường — icon Dock, menu bar của app, ⌘Tab — với cửa sổ chính và một menu-bar item. Settings → General → **Hiển thị trong Dock** tắt icon Dock để chuyển sang dạng chỉ menu bar (`NSApp.setActivationPolicy`), áp dụng lúc khởi động và ngay lập tức.

**Cửa sổ** — `NavigationSplitView` sidebar + detail (`DustlessApp.swift:161-167`). Sidebar (`SidebarView.swift`) liệt kê các module (Overview, Cleanup, Storage, Memory, Network) và, trong **Cleanup**, ba dòng mức: **GREEN**, **YELLOW**, **LOCKED** (BLOCKED). Mỗi dòng mức hiện số lượng và dung lượng. Detail view của Cleanup (`DetailView.swift`) có ô tìm/lọc, nút **Tất cả / Bỏ chọn** cho GREEN và YELLOW, và thanh hành động dưới cùng hiển thị byte đã chọn cùng nút **Xem lại & Xóa** (Cmd-Return). Mục LOCKED được liệt kê nhưng bị vô hiệu và không bao giờ bị xóa. Một lần scan bắt đầu với chọn rỗng — không có gì được chọn trước.

**Dòng finding** (`FindingRow.swift:86`) — menu ngữ cảnh: **Hiện trong Finder**, **Sao chép đường dẫn**.

**Trang xác nhận** (`ConfirmDeleteSheet.swift:17-63`) — liệt kê từng mục đã chọn kèm đường dẫn, rule id, mô tả, dung lượng, và một dòng nguồn gốc trên mỗi mục (trường `note`: ví dụ "rule yêu cầu ≥90 ngày, file mới nhất 0 ngày" hoặc "BLOCKED, ghim bởi /Users/x/repo"). Menu ngữ cảnh giống nhau trên từng dòng.

**Cài đặt** (`SettingsView.swift`, mở qua biểu tượng bánh răng trên toolbar hoặc Cmd-,) — Ngôn ngữ (vi/en/zh), Giao diện (Hệ thống/Sáng/Tối), **Hiển thị trong Dock** (tắt = chỉ menu bar: không icon Dock, không ⌘Tab; `SettingsView.swift:28`), **Mở khi đăng nhập**. Ngôn ngữ, giao diện và chính sách Dock áp dụng ngay lập tức, không cần khởi động lại. Mở khi đăng nhập nằm trong Cài đặt, không phải sidebar (theo R8 trong `docs/RESEARCH-CLEANER-APPS.md:127-131`).

**Menu bar popover** (`MenuBarContent.swift`, được `DustlessApp.swift` trình bày với `.menuBarExtraStyle(.window)`) — nguồn gốc của lần scan gần nhất (tuổi, số rule, thời lượng), một lưới trực tiếp gồm dung lượng trống, byte có thể thu hồi, áp lực bộ nhớ và interface/gateway mạng, cảnh báo scan cũ khi lần đọc gần nhất thất bại, **Quét ngay** / **Xem lại & Dọn**, một dòng cho mỗi module (Overview, Cleanup, Storage, Memory, Network), công tắc AirDrop (AWDL), và **Mở Dustless**, **Cài đặt**, **Thoát**. Nó đọc lại các số trực tiếp khi mở, qua các ngưỡng cũ của store, và không bao giờ tự khởi động một lần scan đầy đủ. Không có điểm số và không có vòng tròn: giá trị chưa đo hiển thị `—`, và một lần scan thất bại nói rõ thay vì trình bày số cũ như số hiện tại.

**Phím tắt** (`DustlessApp.swift:28-40`, `DetailView.swift:206`) — Cmd-R: quét lại; Cmd-1/2/3/4/5: Overview, Cleanup, Storage, Memory, Network; Cmd-,: Cài đặt; Cmd-Return: Xem lại & Xóa.

**Build & chạy** — `bun run build` sinh ra `dist/dustless` (engine). Sau đó `bun run bundle:mac` gói thành `dist/Dustless.app` với engine nhúng tại `Contents/Resources/dustless` (`scripts/bundle-macos.ts:7,33-35,51-59`). Script chạy `swift build -c release`, sao chép binary và engine, ghi `Info.plist`, và ký ad-hoc bundle. Tối thiểu macOS 14.0 (`scripts/bundle-macos.ts:24`).

**Căn cứ thiết kế** — Trục mức (không phải danh mục toolchain) là điều hướng chính vì kết luận an toàn mới chặn hành động phá hủy (R1, `docs/RESEARCH-CLEANER-APPS.md:79-85`). Phần tiêu đề hiển thị tổng thu hồi được của lần quét; thanh hành động hiển thị tổng *đã chọn* theo thời gian thực (R2). Mục bị khóa có toàn bộ khung nhìn kèm lý do kiểm chứng thất bại (R3). Trang xác nhận cho thấy lý do quyết định trên từng mục (R5). Không chọn trước — fail-closed theo thiết kế (R4 mục 3). Cài đặt tách khỏi điều hướng chính (R8).

## AI agent / MCP

`dustless mcp` nói chuyện MCP qua stdio. Tài liệu đầy đủ, cấu hình client cho Claude Code, opencode, Cursor và VS Code, cùng một hội thoại mẫu: **[docs/MCP.md](docs/MCP.md)**. Năm tool: `scan`, `apply`, `list_rules`, `free_space`, `doctor`.

Cổng chặn trong `apply` là phần đáng chú ý nhất. Không có `confirm: true` thì lệnh không xóa gì và trả về đúng kế hoạch đó (`src/mcp/safety.ts:43`). Thứ tự đúng luôn là: scan, cho người dùng thấy số byte, nhận một câu "yes" rõ ràng, rồi gửi lại y hệt lệnh đó kèm `confirm: true`.

Một agent không bao giờ được tự ý đặt `confirm: true`. Lập luận không phải là "xóa cái này có hợp lý không" — mà là "một con người, ngay lúc này, đã đọc đúng con số byte này và đã nói có". Nếu câu trả lời không phải một câu có đã được ghi nhận, lệnh đó là một lần chạy thử.

Ngoài ra: RED từ chối cả lệnh, BLOCKED từ chối cả lệnh, một rule id lạ từ chối cả lệnh, và bất kỳ thứ gì vượt 50 GB đều từ chối trừ khi bạn truyền thêm `allow_large: true` (`src/mcp/safety.ts:7`). Apply là tất cả-hoặc-không — một vấn đề là không xóa gì cả.

## Rules

Database đi kèm là `src/core/default-rules.yaml`. Nó có sẵn 26 rule phủ Gradle, npm, pnpm, bun, uv, pub-cache, Homebrew, Yarn, pip, Go, Cargo, Brave, Chrome, Firefox, Edge, Puppeteer, Android, Colima, Docker và output `node_modules`/`build` của project.

Đặt một file ở `~/.config/dustless/rules.yaml` (hoặc `$XDG_CONFIG_HOME/dustless/rules.yaml`) và nó sẽ được gộp đè lên database đi kèm: một rule có `id` trùng **thay thế** rule gốc, còn id mới thì được **thêm vào** (`src/core/rules.ts:28`). Không có cách nào xóa hẳn một rule gốc — hãy thay nó bằng một rule không match gì cả nếu bạn muốn nó bất lực.

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
| `tier` | `green` hoặc `yellow`. Mọi giá trị khác bị từ chối lúc nạp (`src/core/rules.ts:60`). `red` và `blocked` không gán được: RED là danh sách path, BLOCKED là một kết luận. |
| `desc` | Một dòng, hiển thị trong `rule list`. |
| `paths` | Key là `mac`, `win`, `linux` hoặc `all` (`src/core/rules.ts:7`). `~` nở ra thành home directory; trên Windows `%VAR%` nở từ biến môi trường (`src/core/paths.ts:14`). Mỗi value là một string hoặc một list string. Dấu `*` nở ra thành các thư mục con trực tiếp. |
| `match` | Regex tuỳ chọn, so với basename của từng thư mục mà path tạo ra (`src/core/paths.ts:90`). |
| `minAgeDays` | Nếu file mới nhất bên trong còn trẻ hơn mốc này, finding bị hạ từ GREEN xuống YELLOW (`src/core/scan.ts:132`). |
| `requireVerify` | Tên một bài kiểm chứng chéo: `gradle_version_unused`, `git_clean`, hoặc `not_in_gitignore`. Nếu trượt, finding bị hạ xuống YELLOW **và** bị đánh BLOCKED (`src/core/scan.ts:136`). |
| `nativeCommand` | Tuỳ chọn. Tên tool sở hữu cache đó. Nếu tool đó có trong bảng tiến trình lúc `apply` chạy, cache bị bỏ qua để không phá một lượt cài đặt đang chạy (`src/core/apply.ts:72`). |

Theo CONTRIBUTING, một rule mới mà không có kiểm chứng là bug, không phải tính năng; nếu không kiểm chứng được, hãy đánh dấu nó là `yellow`. Hãy validate trước khi tin:

```sh
dustless rule validate
dustless rule list
```

## Xử lý sự cố

**macOS: thiếu kết quả hoặc `doctor` báo `EPERM`.**
TCC đang che các thư mục khỏi tiến trình. Cấp Full Disk Access trong System Settings › Privacy & Security › Full Disk Access, rồi đóng và mở lại terminal. `doctor` in ra chẩn đoán này và trả exit `1` khi `~/Library/Mail` trả về `EPERM` (`src/cli/doctor.ts`). Lưu ý cái bẫy: thiếu quyền làm cho `~/Library/Caches` trông *nhỏ hơn* thực tế, nên một số cache không bao giờ xuất hiện trong scan.

**Windows: `EBUSY` hoặc `EPERM` khi xóa.**
Antivirus và Windows Search indexer giữ khoá tạm thời. `remove()` thử lại tối đa 4 lần trên Windows với backoff luỹ thừa, rồi bỏ cuộc (`src/core/apply.ts:118`). Hãy tắt indexer hoặc loại trừ thư mục đó, rồi chạy lại.

**Không có gì bị xóa.** Đọc cột `detail`. Các nguyên nhân thường gặp, theo đúng thứ tự bạn sẽ gặp:
- Rule chưa đạt `minAgeDays`. Một ảnh Android system image 3 ngày tuổi với `minAgeDays: 90` là YELLOW theo thiết kế, không phải lỗi.
- Tool sở hữu đang chạy. Nếu một rule khai báo `nativeCommand` và tool đó có trong bảng tiến trình, cache của nó bị bỏ qua để không phá một lượt cài đặt đang chạy (`src/core/apply.ts:73`).
- Kiểm chứng thất bại. Mục đó là BLOCKED và `--yes` không đổi được.
- Path trúng danh sách đỏ, là `$HOME` hoặc thư mục cha của nó, là filesystem root, hoặc đi qua một thư mục là symlink (`src/core/apply.ts:104`, `src/core/paths.ts:167`).

**`apply` hủy mà không xóa gì cả.** Không có `--yes` thì nó hỏi trước, và nó chỉ hỏi trên stdin là TTY: trong một CI job, một pipe hay một wrapper script, nó in bản tổng kết rồi dừng (`src/cli/scan.ts`). Với `--json` cũng vậy, vì không thể hỏi. Hãy chạy trong terminal thật, hoặc dùng MCP server, vì nó có cổng xác nhận tường minh riêng.

**`freed` báo `0` dù file đã bị xóa.** `freed` là mức thay đổi dung lượng trống trên cả volume. Nếu một tiến trình khác ghi vào đĩa trong lúc chạy, chênh lệch bị kẹp về `0` (`src/core/apply.ts:35`). Hãy đọc `status` của từng outcome.

**Một rule tôi viết cứ ở YELLOW.** Hoặc `minAgeDays` chưa đạt, hoặc `requireVerify` đang trượt. `scan` in lý do ở cột `note`, ngay dưới path. Hãy sửa nguyên nhân gốc — một thay đổi chưa commit, một phiên bản tool mà project vẫn còn ghim — rồi scan lại.

## Đóng góp

Xem [CONTRIBUTING.md](CONTRIBUTING.md) và [docs/TESTING.md](docs/TESTING.md). `main` được bảo vệ, kể cả với chính chủ repo: không push thẳng được, một status check bắt buộc, lịch sử tuyến tính, và mọi thay đổi đều cần `@Dung-L3` review với tư cách code owner. Fork, tạo branch, commit, mở pull request.

Luật vàng: **không thêm rule dọn dẹp vào rule database nếu chưa viết phần kiểm chứng chứng minh nó an toàn.** Một rule xóa file mà không kiểm tra xem còn ai cần đến chúng là bug, không phải tính năng.

Trước khi mở PR: `bun run typecheck`, rồi `bun test`, rồi `bun run build`.

## Giấy phép

MIT