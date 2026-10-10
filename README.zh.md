# Dustless

[English](README.md) · [Tiếng Việt](README.vi.md) · [中文](README.zh.md)

**开发者机器的磁盘清理工具。** 它测量规则数据库里的每一个工具链缓存，通过读取你真实项目来证明每个缓存已无人使用，然后只删除通过验证的部分。

Dustless 是单个已编译的二进制文件，支持 macOS、Windows 和 Linux。不需要运行时，不驻留后台，不需要管理员权限。

---

## 问题

在开发机上，几乎所有可回收空间都在工具链缓存里 —— Gradle、npm、pnpm、bun、uv、pub-cache、Cargo、Go modules、Android SDK 镜像。通用清理工具看的是完全不同的位置：`~/Library/Caches`、系统日志、`.DS_Store`、没用上的应用。

在参考机器上实测（macOS，Bun 1.3.13，2026-10-11）：`du -sh ~/Library/Caches` 报告 **228 MB** —— 而这个数字本身还偏低，因为没有 Full Disk Access 时多个缓存子目录返回 `Operation not permitted`。同一时期，`dustless scan` 仅从工具链缓存就报告了 **13.8 GB 可回收**（`Thu hồi được 13.8 GB`）。清理工具看的位置和字节真正所在的位置之间差了 60 倍 —— 而装着几十 GB 的那些目录，恰恰是通用工具不敢碰的，因为它无法证明它们已经没人用。

## 差异：先交叉扫描，再删除

Dustless 不会仅仅因为一个缓存位于缓存目录里就删掉它。它先证明没有东西还需要它。

以 Gradle 为例。`~/.gradle/caches/8.12` 和 `~/.gradle/caches/8.14` 在结构上完全相同。磁盘上没有任何东西能说明哪个已经废弃。唯一的办法是读取机器上每一个真实项目：

- 遍历 `~/Innotech`、`~/Personal`、`~/Developer`、`~/Projects`、`~/repos`，外加 `$HOME` 下两层（`src/core/verify/gradle.ts:32`）。
- 读取 `gradle-wrapper.properties`、`gradle.properties`、`build.gradle`、`build.gradle.kts`（`src/core/verify/gradle.ts:18`）。
- 从 `distributionUrl` 中解析出 `gradle-<version>-bin.zip`（`src/core/verify/gradle.ts:25`）。
- 跳过 vendored 副本，这样藏在 `build/`、`SourcePackages/`、`node_modules/`、`Pods/`、`DerivedData/` 或 `.gradle/` 里的 wrapper 永远不会被算作真实项目（`src/core/verify/gradle.ts:6`）。
- 如果还有任何项目锁定 8.12，该缓存被标记为 **BLOCKED** 并留在磁盘上。

遍历受 200,000 条目的预算限制，不会在失控的情况下无限扩张（`src/core/verify/gradle.ts:27`）。同样的思路驱动 `node_modules` 的 `git_clean`：进行中的 merge、未提交的改动或未推送的提交，都会让该目录不可删除（`src/core/verify/git.ts:30`）。

## 四个安全等级

| 等级 | 含义 | `apply` 的行为 |
| --- | --- | --- |
| 🟢 **GREEN** | 纯可重建缓存。若规则要求交叉验证，验证已通过。 | 在汇总确认后自动删除 |
| 🟡 **YELLOW** | 可能仍在使用中 —— VM 磁盘、模拟器 AVD、构建产物。也包括因某项检查未通过而被降级的条目。 | 逐条询问 |
| ⛔ **BLOCKED** | 规则要求验证，而验证失败。 | **永不删除。** `--yes` 也不行，任何标志都不行 |
| 🔴 **RED** | 硬编码的受保护路径清单：Keychain、Mail、iCloud、`*-wal`/`*-shm`、`Preferences`、`.git`、Documents、Desktop、Pictures、Movies、Music、Contacts、Reminders、Calendar、Finance、Messages（`src/core/paths.ts:81`） | 永远不会成为 finding。删除前会再检查一次 |

### 为什么 BLOCKED 无法被覆盖

这个工具的早期版本会把验证失败的条目降级为 YELLOW。结果发生了一起真实事故：一次带 `--yes` 的运行删除了某个活跃项目仍在使用的 Gradle 缓存，用户约 36 GB 的文件随之丢失。

所以行为从根上改了。验证失败的 finding 会被打上 `blocked` 标记，而这个标记在四个互相独立的位置被检查 —— scan 负责标记，apply 的汇总阶段把它排除，`apply()` 再查一次，MCP 安全层直接拒绝整个调用。`--yes` 跳过的是提问。它无法伪造一次通过的验证，也无法解除封锁。RED 同理：它是一组编译进二进制文件的正则。没有任何标志、规则文件或 MCP 参数能触及它。

## 安装

### Release 二进制文件

推送一个 `v*` tag，build 工作流会编译四个目标并附到 release 上：`dustless-macos`（Intel）、`dustless-macos-arm64`（Apple Silicon）、`dustless-windows.exe` 和 `dustless-linux`。下载对应你机器的那个，放到 `PATH` 下的任意位置即可。

```sh
dustless doctor     # 确认它能运行且能读取你的缓存
```

`doctor` 不需要 Full Disk Access。它会打印平台、规则目录、规则数量、总容量和剩余容量，以及逐路径的可读性探测。

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

`scan` 只读。无论你传什么标志，它都不可能删除任何东西。

**第 2 步 —— 在汇总之后删除。**

```sh
dustless apply
```

在移除任何东西之前，你会看到：

```
Sẽ xóa 4 mục tự động (5.8 GB)
Sẽ hỏi  2 mục (8.0 GB)
Tổng   13.8 GB

Xóa? [y/N]
```

输入 `y` 然后回车继续。其他任何字符 —— 包括直接回车 —— 都会取消，且不删除任何东西。界面是越南语，因为二进制文件输出的就是越南语，所以这里原样保留。

**第 3 步 —— 回答黄色条目。** 每个 YELLOW 条目都会单独问你，一条一条：

```
🟡 YELLOW xóa 5.3 GB ở /Users/mac/Library/Android/sdk/system-images? [y/N]
```

`y` 删除该条目。其他任何字符都会跳过它并继续。没有任何东西会在你不知情的情况下被批量处理。

## CLI 参考

下面每个命令都在 `src/cli.ts` 中实现。

| 命令 | 行为 |
| --- | --- |
| `dustless scan` | 交叉扫描所有规则，按大小排序列出 finding，并给出各等级汇总和可回收字节数。只读。 |
| `dustless ui` | 在 127.0.0.1 上启动本地浏览器界面并打开它。见 [Web UI](#web-ui)。 |
| `dustless apply` | Scan，显示汇总，询问 `Xóa? [y/N]`，然后删除 GREEN 并逐条询问 YELLOW。若有任何条目失败，退出码为 `1`。 |
| `dustless rule list` | 打印规则数据库及其等级和描述，并说明加载来源。 |
| `dustless rule show <id>` | 以 JSON 打印单条规则。 |
| `dustless rule add <id> <green\|yellow> <desc> <path> [path…]` | 以 `paths.all` 向 `~/.config/dustless/rules.yaml` 追加一条新规则。 |
| `dustless rule validate [file]` | 解析并校验一个规则文件。省略路径则校验合并后的数据库。 |
| `dustless doctor` | 平台、配置目录、规则数量、总容量/剩余容量、关键路径可读性、Full Disk Access 检查。 |
| `dustless mcp` | 通过 stdio 提供 MCP 服务供 AI agent 使用。见 [docs/MCP.md](docs/MCP.md)。 |
| `dustless version` | 打印 `0.1.0`。`dustless help` 打印用法，直接运行 `dustless` 也会打印用法。 |

### 标志

| 标志 | 作用 |
| --- | --- |
| `--json` | 让 `scan`、`apply`、`rule list` 和 `doctor` 以机器可读格式输出到 stdout。同时关闭交互式提问。 |
| `--quiet` | 抑制面向人类阅读的输出行。 |
| `--yes` | 跳过确认。既跳过汇总提问，**也**跳过每条 YELLOW 的提问。它不跳过验证，也无法解除 BLOCKED 或 RED。 |
| `--port <n>` | 仅用于 `ui`。监听端口。必须在 1024-65535 之间。默认为 `4173`。 |
| `--no-open` | 仅用于 `ui`。启动服务但不打开浏览器。 |
| `--help` | 用法说明。可与任意命令一起使用。 |

## Web UI

`dustless ui` 启动一个本地服务，并在你的浏览器里打开界面。

```sh
dustless ui                        # http://127.0.0.1:4173
dustless ui --port 8080            # 自己选一个端口
dustless ui --no-open              # 启动但不打开浏览器
```

它只绑定 **127.0.0.1** —— 绝不绑 `0.0.0.0`，绝不绑到可路由的网络接口（`src/ui/server.ts:19`，`src/ui/server.ts:161`）。超出 1024-65535 范围的端口会在套接字打开之前就被拒绝；如果端口已被占用，服务会直接退出，而不是悄悄地换到别处去监听。

它还会按 Host 头拒绝请求。Host 不是 `127.0.0.1` 或 `localhost` 的请求，在路由执行前就会收到 `403`（`src/ui/server.ts:103`，`src/ui/server.ts:122`）。并且每个响应都带上严格的 CSP：`default-src 'none'; script-src 'self'`（`src/ui/server.ts:24`）。

为什么这很重要：这个进程有一个会删除你磁盘文件的 `POST /api/apply` 端点。任何能访问该端口的东西都能访问删除端点。只绑回环，加上 Host 检查，才是一次 DNS rebinding 和一个被清空的主目录之间真正的屏障。

路由：`GET /api/scan`、`GET /api/rules`、`GET /api/space`、`POST /api/apply`。`Ctrl+C`（或 `SIGTERM`）可停止它。

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
| `tier` | `green` 或 `yellow`。其他值在加载时被拒绝（`src/core/rules.ts:56`）。 |
| `desc` | 一行说明，显示在 `rule list` 中。 |
| `paths` | key 为 `mac`、`win`、`linux` 或 `all`（`src/core/rules.ts:7`）。`~` 展开为你的主目录；在 Windows 上 `%VAR%` 从环境变量展开（`src/core/paths.ts:13`）。每个值是一个字符串或字符串列表。`*` 展开为它父目录下的各个子目录。 |
| `match` | 可选正则，作用于所考虑目录的 basename。 |
| `minAgeDays` | 如果其中最新的文件比这个时间更年轻，finding 会从 GREEN 降级为 YELLOW（`src/core/scan.ts:72`）。 |
| `requireVerify` | 一项交叉验证的名称：`gradle_version_unused`、`git_clean` 或 `not_in_gitignore`。若失败，finding 会降级为 YELLOW **并且**被标记为 BLOCKED（`src/core/scan.ts:76`）。 |

按照 CONTRIBUTING 的说法，一条没有验证的新规则是 bug，不是功能。如果无法验证它，就把它标为 `yellow`。

信任它之前先校验：

```sh
dustless rule validate
dustless rule list
```

## 故障排查

**macOS：结果缺失，或 `doctor` 报 `EPERM`。**
TCC 在对进程隐藏目录。请在 系统设置 › 隐私与安全性 › 完全磁盘访问权限 中授权，然后退出并重新打开终端。`doctor` 会直接打印这个诊断并返回非零退出码（`src/cli.ts:214`）。注意这个陷阱：缺少授权会让 `~/Library/Caches` 看起来比实际*更小*，于是某些缓存根本不会出现在 scan 结果里。

**Windows：删除时报 `EBUSY` 或 `EPERM`。**
杀毒软件和 Windows 搜索索引器会持有短暂的锁。在 Windows 上 `remove()` 最多重试 4 次，采用指数退避，之后放弃（`src/core/apply.ts:98`）。关闭索引器或把该目录加入排除列表，然后重跑。

**什么都没有被删除。** 读 `detail` 列。常见原因，按你实际会遇到的顺序排列：
- 规则未达到 `minAgeDays`。一个 3 天大的 Android system image 配 `minAgeDays: 90`，成为 YELLOW 是设计如此，不是故障。
- 工具正在运行。如果 `npm`、`npx`、`pnpm` 或 `yarn` 出现在进程表里，它的缓存会被跳过，以免破坏正在进行的安装（`src/core/apply.ts:9`）。
- 验证失败。该条目是 BLOCKED，`--yes` 也无法改变。
- 路径命中红色清单、是 `$HOME` 或它的父目录、或是文件系统根目录（`src/core/apply.ts:86`）。

**`apply` 立刻退出。** 如果 stdout 不是 TTY —— CI 任务、管道、包装脚本 —— `apply` 会拒绝提问且不删除任何东西（`src/cli.ts:130`）。请在真正的终端里运行。做自动化时，请用 MCP server，它有自己显式的确认闸门。

**我写的某条规则一直是 YELLOW。** 要么 `minAgeDays` 没达到，要么 `requireVerify` 正在失败。`scan` 会在路径下方的 `note` 列里打印原因。解决根本原因 —— 未提交的改动、某个项目仍然锁定的工具版本 —— 然后重新 scan。

## 参与贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。`main` 受保护，对仓库所有者同样如此。Fork、建分支、提交、开 pull request。无法直接 push。

黄金法则：**在写下证明规则安全的验证逻辑之前，不要往规则数据库里加清理规则。** 一条不检查还有没有人需要这些文件就直接删除的规则，是 bug，不是功能。

开 PR 之前：依次运行 `bun run typecheck`、`bun test`、`bun run build`。

## 许可证

MIT