# Dustless

[English](README.md) · [Tiếng Việt](README.vi.md) · [中文](README.zh.md)

**开发者机器的磁盘清理工具。** 它测量规则数据库里的每一个工具链缓存，通过读取你真实项目来证明每个缓存已无人使用，然后只删除通过验证的部分。

Dustless 是单个已编译的二进制文件，支持 macOS、Windows 和 Linux。不需要运行时，不驻留后台，不需要管理员权限。版本号 0.1.2 在构建时从 `package.json` 读取（`src/cli.ts:14`）—— 一个数字，一个来源。

---

## 问题

在开发机上，几乎所有可回收空间都在工具链缓存里 —— Gradle、npm、pnpm、bun、uv、pub-cache、Cargo、Go modules、Android SDK 镜像。通用清理工具看的是完全不同的位置：`~/Library/Caches`、系统日志、`.DS_Store`、没用上的应用。

在参考机器上实测（macOS，Bun 1.3.13，2026-10-11）：`du -sh ~/Library/Caches` 报告 **213M** —— 而这个数字本身还偏低，因为没有 Full Disk Access 时多个缓存子目录返回 `Operation not permitted`。同一天，`dustless scan` 仅从工具链缓存就报告了 **3.4 GB 可回收**（`Thu hồi được 3.4 GB`）。清理工具看的位置和字节真正所在的位置之间差了 16 倍 —— 而装着 gigabyte 级数据的那些目录，恰恰是通用工具不敢碰的，因为它无法证明它们已经没人用。这两个数字都会随你的缓存变动；它们是某台机器在某一天的快照，不是基准测试。

## 差异：先交叉扫描，再删除

Dustless 不会仅仅因为一个缓存位于缓存目录里就删掉它。它先证明没有东西还需要它。

以 Gradle 为例。`~/.gradle/caches/8.12` 和 `~/.gradle/caches/8.14` 在结构上完全相同。磁盘上没有任何东西能说明哪个已经废弃。唯一的办法是读取机器上每一个真实项目：

- 向下遍历 `$HOME` 最多 5 层，跳过点目录和一个固定的跳过名单，并在第一个看起来像项目的目录停下：`.git`、`package.json`、`pubspec.yaml`、`gradlew`、`settings.gradle` 或 `settings.gradle.kts`（`src/core/verify/gradle.ts:31`、`src/core/verify/gradle.ts:61`）。
- 从每个项目根再向下遍历最多 12 层，读取 `gradle-wrapper.properties`、`gradle.properties`、`build.gradle`、`build.gradle.kts`（`src/core/verify/gradle.ts:18`）。
- 从 `distributionUrl` 里解析出版本号 —— `gradle-<version>-bin.zip` 或 `-all.zip`（`src/core/verify/gradle.ts:25`）。
- 跳过 vendored 副本 —— `build/`、`SourcePackages/`、`.dartServer/`、`node_modules/`、`.gradle/`、`.pub-cache/`、`DerivedData/`、`Pods/`、`ephemeral` —— 藏在这些目录里的 wrapper 永远不会被算作真实项目（`src/core/verify/gradle.ts:6`）。
- 如果还有任何项目锁定 8.12，该缓存被标记为 **BLOCKED** 并留在磁盘上。

遍历有边界：12 层，合计 200,000 个目录条目，所以不会失控扩张（`src/core/verify/gradle.ts:27`）。同样的思路驱动 `node_modules` 的 `git_clean`：进行中的操作（`MERGE_HEAD`、`CHERRY_PICK_HEAD`、`rebase-merge` 等）、未提交的改动或未推送的提交，都会让该目录不可删除（`src/core/verify/git.ts:11`、`src/core/verify/git.ts:30`）。

## 四个安全等级

| 等级 | 含义 | `apply` 的行为 |
| --- | --- | --- |
| 🟢 **GREEN** | 纯可重建缓存。若规则要求交叉验证，验证已通过。 | 你确认汇总后自动删除 |
| 🟡 **YELLOW** | 可能仍在使用中 —— VM 磁盘、模拟器 AVD、构建产物 —— 或因未达到 `minAgeDays` 而被降级的规则（`src/core/scan.ts:72`）。 | 逐条询问 |
| ⛔ **BLOCKED** | 规则要求验证，而验证失败（`src/core/scan.ts:76`）。记在 `totals.blocked` 下，且不计入 `reclaimable`（`src/core/scan.ts:28`）。 | **永不删除。** `--yes` 也不行，任何标志都不行 |
| 🔴 **RED** | 硬编码的受保护路径清单：Keychain、Mail、iCloud、`*-wal`/`*-shm`、`Preferences`、`.git`、Documents、Desktop、Pictures、Movies、Music、Contacts、Reminders、Calendar、Finance、Passes、Keynotes、Messages、`Application Support/com.apple.{Photos,MobileSync,Notes,Trial}`（`src/core/paths.ts:81`） | 永远不会成为 finding（`src/core/scan.ts:42`）。删除前会再检查一次（`src/core/apply.ts:54`） |

BLOCKED 不是弱化版的 RED。RED 是一份静态路径清单，任何东西都删不掉它。BLOCKED 是一个实时判定：Dustless 试图证明某个缓存已无人使用，但没能证明。

### `apply` 采用 fail-closed

每一次删除都以 rule id 为键，而缺失的键会解析为 `skip`（`src/core/apply.ts:71`）：

```ts
const action = opts.tiers?.[finding.ruleId] ?? "skip";
```

拼错的 id、payload 漏掉的 id、scan 根本没产出的 rule —— 全部解析为 skip，绝不会变成该规则自己的 tier。早期版本默认取规则自身的 tier，于是漏掉一个键就等于静默地说“删除”；那正是从一台真实机器上带走约 36 GB 的原因。

这个默认值是兜底，而不是机制。每个调用方都自己构造映射：CLI 从正在运行的 scan 构造（`src/cli.ts:134`），UI 从你实际勾选的内容构造（`src/ui/public/app.js:161`），MCP 从它事先校验过的 rule id 构造（`src/mcp/tools.ts:188`）。

### 为什么 BLOCKED 无法被覆盖

封锁在四个互相独立的位置被强制执行：scan 打上标记，apply 的汇总阶段把这些 finding 排除出待删集合（`src/cli.ts:118`），`apply()` 在碰文件系统之前再查一次（`src/core/apply.ts:60`），MCP 安全层直接拒绝整个调用（`src/mcp/safety.ts:88`）。`--yes` 跳过的是提问。它无法伪造一次通过的验证，也无法解除封锁。RED 同理：它是一组编译进二进制文件的正则。没有任何标志、规则文件或 MCP 参数能触及它。浏览器 UI 守的是同一条线：被封锁的 finding 得到的是一条提示而不是删除按钮（`src/ui/public/app.js:303`），而所有 finding 都被封锁的规则会以 `skip` 发送（`src/ui/public/app.js:164`）。

## 安装

### Release 二进制文件

推送一个 `v*` tag，build 工作流会编译四个目标并附到 release 上：`dustless-macos-arm64`、`dustless-macos-x64`、`dustless-linux-x64`、`dustless-windows-x64.exe`（`.github/workflows/release.yml:21`）。下载对应你机器的那个，放到 `PATH` 下的任意位置即可。

```sh
dustless doctor     # 确认它能运行且能读取你的缓存
```

`doctor` 会打印平台、你的主目录、规则目录、规则数量、总容量和剩余容量，以及逐路径的可读性探测。当它需要的某个路径读不到时，退出码非零（`src/cli.ts:265`）。

### 从源码运行

需要 Bun 1.3 或更高版本。

```sh
git clone https://github.com/Dung-L3/dustless
cd dustless
bun install
bun run build          # 生成 dist/dustless
./dist/dustless scan
```

你也可以不构建，直接运行 TypeScript 入口：`bun src/cli.ts scan`。

## 快速开始

如果你从来没在终端里用过工具，就照下面做。

**第 1 步 —— 只看，不删除。**

```sh
dustless scan
```

参考机器上的真实输出：

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

`scan` 只读。无论你传什么标志，它都不可能删除任何东西。

**第 2 步 —— 在汇总之后删除。**

```sh
dustless apply
```

在移除任何东西之前你会看到这些 —— 包括在任何 GREEN 条目之前：

```
Sẽ xóa 3 mục tự động (611.4 MB)
Sẽ hỏi  3 mục (2.8 GB)
Tổng   3.4 GB
Xóa? [y/N]
```

输入 `y` 然后回车继续。其他任何字符 —— 包括直接回车 —— 都会取消，且不删除任何东西。如果存在被封锁的 finding，汇总会另外说明有多少条目无论如何都无法删除（`src/cli.ts:154`）。界面是越南语，因为二进制文件输出的就是越南语，所以这里原样保留。

**第 3 步 —— 回答黄色条目。** 每个 YELLOW 条目都会单独问你，一条一条：

```
🟡 YELLOW xóa 2.8 GB ở /Users/mac/Library/Android/sdk/ndk? [y/N]
```

`y` 删除该条目。其他任何字符都会跳过它并继续。没有任何东西会在你不知情的情况下被批量处理。

## CLI 参考

下面每个命令都在 `src/cli.ts` 中实现。

| 命令 | 行为 |
| --- | --- |
| `dustless scan` | 交叉扫描所有规则，按大小排序列出 finding，并给出各等级汇总和可回收字节数。只读。 |
| `dustless apply` | Scan，打印汇总，询问 `Xóa? [y/N]`，然后删除 GREEN 并逐条询问 YELLOW。若有任何条目失败，退出码为 `1`。 |
| `dustless ui` | 在 127.0.0.1 上启动本地浏览器界面并打开它。见 [Web UI](#web-ui)。 |
| `dustless rule list` | 打印规则数据库及其等级和描述，并说明加载来源。 |
| `dustless rule show <id>` | 以 JSON 打印单条规则。 |
| `dustless rule add <id> <green\|yellow> <desc> <path> [path…]` | 以 `paths.all` 向 `~/.config/dustless/rules.yaml` 追加一条新规则。 |
| `dustless rule validate [file]` | 解析并校验一个规则文件。省略路径则校验合并后的数据库。 |
| `dustless doctor` | 平台、主目录、配置目录、规则数量、总容量/剩余容量、关键路径可读性、Full Disk Access 检查。 |
| `dustless mcp` | 通过 stdio 提供 MCP 服务供 AI agent 使用。见 [docs/MCP.md](docs/MCP.md)。 |
| `dustless version` | 打印 `0.1.2`。`dustless help` 以及直接运行 `dustless` 都会打印用法。 |

### 标志

| 标志 | 作用 |
| --- | --- |
| `--json` | 为 `scan`、`apply`、`rule list`、`doctor`、`version` 在 stdout 输出一个 JSON 对象。对 `apply` 它同时意味着取消：没有 `--yes` 就没有提问，所以什么都不会删（`src/cli.ts:148`）。 |
| `--quiet` | 抑制面向人类阅读的输出行。 |
| `--yes` | 跳过确认。既跳过汇总提问，**也**跳过每条 YELLOW 的提问。它不跳过验证，也无法解除 BLOCKED 或 RED。 |
| `--port <n>` | 仅用于 `ui`。监听端口。必须在 1024-65535 之间，在套接字打开之前就检查（`src/cli.ts:176`）。默认为 `4173`。 |
| `--no-open` | 仅用于 `ui`。启动服务但不打开浏览器。 |
| `--help` | 用法说明，但仅当它是唯一参数时 —— `dustless --help`。在另一个命令词之后，命令本身优先：`dustless scan --help` 会执行一次 scan。 |

### `apply --json`

`apply --json` 在 stdout 上恰好打印一个 JSON 对象，在每一条走到它的路径上 —— 已删除、无可删除、已取消 —— 键为 `outcomes`、`freed`、`freeBefore`、`freeAfter`、`elapsedMs`（`src/types.ts:56`）。`freed` 是 `max(0, freeAfter - freeBefore)`：整个卷上剩余空间的差值，不是被删条目之和，所以如果期间有别的东西占满了磁盘，一次真实删除之后它也可能读出 `0`（`src/core/apply.ts:33`）。硬错误 —— 比如格式错误的 `~/.config/dustless/rules.yaml` —— 仍然以 `1` 退出，消息在 stderr 上，stdout 上什么都没有（`src/cli.ts:300`）。

## Web UI

`dustless ui` 启动一个本地服务，并在你的浏览器里打开界面。

```sh
dustless ui                        # http://127.0.0.1:4173
dustless ui --port 8080            # 自己选一个端口
dustless ui --no-open              # 启动但不打开浏览器
```

它只绑定 **127.0.0.1**（`src/ui/server.ts:19`、`src/ui/server.ts:200`）。超出 1024-65535 范围的端口会在套接字打开之前就被拒绝；如果端口已被占用，命令会以 `EADDRINUSE` 失败，而不是悄悄地换到别处去监听。`Ctrl+C`（或 `SIGTERM`）可停止它。

这个进程有一个会删除你磁盘文件的 `POST /api/apply` 端点，所以这里的护栏才是重点：

- 只有 `Host` 为 `127.0.0.1` 或 `localhost` 的请求能通过处理器的第一行；其他任何请求在路由执行前就会收到 `403`（`src/ui/server.ts:116`、`src/ui/server.ts:147`）。
- 任何带非回环 `Origin` 的非 `GET` 请求都是 `403`（`src/ui/server.ts:121`、`src/ui/server.ts:155`）。
- 任何没有 `Content-Type: application/json` 的非 `GET` 请求都是 `415`（`src/ui/server.ts:161`）。
- 超过 1 MiB 的 body 是 `413`；`tiers` 不是 rule id 到 `green`/`yellow`/`skip` 的对象的 payload 是 `400`（`src/ui/server.ts:99`）。

最后两条正是为什么在 UI 打开期间，一个随机网页无法删除你的缓存。跨源表单或 `fetch` POST 属于 CORS 的*简单请求*：没有预检，而且浏览器会自行设置 `Host: 127.0.0.1:<port>`，所以 Host 检查挡不住它。`Origin` 和 `Content-Type` 检查能挡 —— 简单请求无法设置这两者。

每个响应还携带 `default-src 'none'; script-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`、`X-Content-Type-Options: nosniff`、`Referrer-Policy: no-referrer` 和 `Cache-Control: no-store`（`src/ui/server.ts:24`、`src/ui/server.ts:143`）。

路由：`GET /api/scan`、`GET /api/rules`、`GET /api/space`、`POST /api/apply`。

## AI agent / MCP

`dustless mcp` 通过 stdio 讲 MCP。完整文档、Claude Code / opencode / Cursor / VS Code 的客户端配置，以及一段完整的对话示例：**[docs/MCP.md](docs/MCP.md)**。五个工具：`scan`、`apply`、`list_rules`、`free_space`、`doctor`。

`apply` 上的那道闸门才是关键。没有 `confirm: true` 时，这次调用不删除任何东西，而是返回确切的计划（`src/mcp/safety.ts:43`）。正确顺序始终是：scan，把字节数展示给用户，得到一个明确的"是"，然后把完全相同的请求加上 `confirm: true` 再发一次。

agent 绝不能自作主张地设置 `confirm: true`。这里的判断标准不是"删掉它合不合理"，而是"一个人，此刻，是否读到了这个确切的字节数并说了是"。如果答案不是一次被记录下来的同意，这次调用就是一次空跑。

除此之外：RED 路径会拒绝整个调用，BLOCKED 条目会拒绝整个调用，未知的 rule id 会拒绝整个调用，超过 50 GB 的批次也会被拒绝，除非你同时传 `allow_large: true`（`src/mcp/safety.ts:7`）。apply 是全有或全无 —— 只要有一个问题，就什么都不删。

## 规则

内置数据库是 `src/core/default-rules.yaml`，自带 26 条规则，覆盖 Gradle、npm、pnpm、bun、uv、pub-cache、Homebrew、Yarn、pip、Go、Cargo、Brave、Chrome、Firefox、Edge、Puppeteer、Android、Colima、Docker，以及项目的 `node_modules`/`build` 产物。

把文件放在 `~/.config/dustless/rules.yaml`（或 `$XDG_CONFIG_HOME/dustless/rules.yaml`），它会覆盖式合并到内置数据库上：`id` 相同的规则**替换**原有规则，新的 `id` 则**追加**进去（`src/core/rules.ts:18`）。没有办法删除内置规则 —— 如果想让某条规则失效，就用一条什么都匹配不上的规则去替换它。

一条真实的规则：

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

| 字段 | 含义 |
| --- | --- |
| `id` | 唯一。替换同 `id` 的内置规则。 |
| `tier` | `green` 或 `yellow`。其他值在加载时被拒绝（`src/core/rules.ts:56`）。`red` 和 `blocked` 无法赋值：RED 是一份路径清单，BLOCKED 是一个判定。 |
| `desc` | 一行说明，显示在 `rule list` 中。 |
| `paths` | key 为 `mac`、`win`、`linux` 或 `all`（`src/core/rules.ts:7`）。`~` 展开为你的主目录；在 Windows 上 `%VAR%` 从环境变量展开（`src/core/paths.ts:13`）。每个值是一个字符串或字符串列表。`*` 展开为它父目录下的各个子目录。 |
| `match` | 可选正则，作用于该 path 产生的每个目录的 basename（`src/core/paths.ts:72`）。 |
| `minAgeDays` | 如果其中最新的文件比这个时间更年轻，finding 会从 GREEN 降级为 YELLOW（`src/core/scan.ts:72`）。 |
| `requireVerify` | 一项交叉验证的名称：`gradle_version_unused`、`git_clean` 或 `not_in_gitignore`。若失败，finding 会降级为 YELLOW **并且**被标记为 BLOCKED（`src/core/scan.ts:76`）。 |
| `nativeCommand` | 可选。标明拥有该缓存的工具名。如果 `apply` 运行时该工具出现在进程表里，该缓存会被跳过，以免破坏正在进行的安装（`src/core/apply.ts:66`）。 |

按照 CONTRIBUTING 的说法，一条没有验证的新规则是 bug，不是功能；如果你无法验证它，就把它标为 `yellow`。信任它之前先校验：

```sh
dustless rule validate
dustless rule list
```

## 故障排查

**macOS：结果缺失，或 `doctor` 报 `EPERM`。**
TCC 在对进程隐藏目录。请在 系统设置 › 隐私与安全性 › 完全磁盘访问权限 中授权，然后退出并重新打开终端。`doctor` 会打印这个诊断，并在 `~/Library/Mail` 返回 `EPERM` 时以 `1` 退出（`src/cli.ts:259`）。注意这个陷阱：缺少授权会让 `~/Library/Caches` 看起来比实际*更小*，于是某些缓存根本不会出现在 scan 结果里。

**Windows：删除时报 `EBUSY` 或 `EPERM`。**
杀毒软件和 Windows 搜索索引器会持有短暂的锁。在 Windows 上 `remove()` 最多重试 4 次，采用指数退避，之后放弃（`src/core/apply.ts:98`）。关闭索引器或把该目录加入排除列表，然后重跑。

**什么都没有被删除。** 读 `detail` 列。常见原因，按你实际会遇到的顺序排列：
- 规则未达到 `minAgeDays`。一个 3 天大的 Android system image 配 `minAgeDays: 90`，成为 YELLOW 是设计如此，不是故障。
- 拥有它的工具正在运行。如果一条规则声明了 `nativeCommand` 且该工具出现在进程表里，它的缓存会被跳过，以免破坏正在进行的安装（`src/core/apply.ts:9`）。
- 验证失败。该条目是 BLOCKED，`--yes` 也无法改变。
- 路径命中红色清单、是 `$HOME` 或它的父目录、或是文件系统根目录（`src/core/apply.ts:86`）。

**`apply` 取消了而什么也没删。** 没有 `--yes` 时它会先问，而且只在 stdin 是 TTY 时才问：在 CI 任务、管道或包装脚本里，它打印完汇总就停（`src/cli.ts:157`）。带 `--json` 时同样如此，因为它无法提问。请在真正的终端里运行，或者改用 MCP server，它有自己显式的确认闸门。

**`freed` 显示 `0` 但文件确实被删了。** `freed` 是整个卷上剩余空间的变化量。如果运行期间有别的进程往磁盘写数据，这个差值会被压到 `0`（`src/core/apply.ts:33`）。请改看每条 outcome 的 `status`。

**我写的某条规则一直是 YELLOW。** 要么 `minAgeDays` 没达到，要么 `requireVerify` 正在失败。`scan` 会在路径下方的 `note` 列里打印原因。解决根本原因 —— 未提交的改动、某个项目仍然锁定的工具版本 —— 然后重新 scan。

## 参与贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [docs/TESTING.md](docs/TESTING.md)。`main` 受保护，对仓库所有者同样如此：无法直接 push，有一个必需的状态检查，历史必须线性，并且每次改动都需要 `@Dung-L3` 以 code owner 身份 review。Fork、建分支、提交、开 pull request。

黄金法则：**在写下证明规则安全的验证逻辑之前，不要往规则数据库里加清理规则。** 一条不检查还有没有人需要这些文件就直接删除的规则，是 bug，不是功能。

开 PR 之前：依次运行 `bun run typecheck`、`bun test`、`bun run build`。

## 许可证

MIT