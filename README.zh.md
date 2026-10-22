# Dustless

[English](README.md) · [Tiếng Việt](README.vi.md) · [中文](README.zh.md)

**开发者机器的磁盘清理工具。** 它测量规则数据库里的每一个工具链缓存，通过读取你真实项目来证明每个缓存已无人使用，然后只删除通过验证的部分。

Dustless 是单个已编译的二进制文件，支持 macOS、Windows 和 Linux。不需要运行时，不驻留后台，不需要管理员权限。版本号 0.5.0 在构建时从 `package.json` 读取（`src/cli/context.ts`）—— 一个数字，一个来源。

---

## 问题

在开发机上，几乎所有可回收空间都在工具链缓存里 —— Gradle、npm、pnpm、bun、uv、pub-cache、Cargo、Go modules、Android SDK 镜像。通用清理工具看的是完全不同的位置：`~/Library/Caches`、系统日志、`.DS_Store`、没用上的应用。

在参考机器上实测（macOS，Bun 1.3.13，2026-10-11）：`du -sh ~/Library/Caches` 报告 **213M** —— 而这个数字本身还偏低，因为没有 Full Disk Access 时多个缓存子目录返回 `Operation not permitted`。同一天，`dustless scan` 仅从工具链缓存就报告了 **3.4 GB 可回收**（`Thu hồi được 3.4 GB`）。清理工具看的位置和字节真正所在的位置之间差了 16 倍 —— 而装着 gigabyte 级数据的那些目录，恰恰是通用工具不敢碰的，因为它无法证明它们已经没人用。这两个数字都会随你的缓存变动；它们是某台机器在某一天的快照，不是基准测试。

## 差异：先交叉扫描，再删除

Dustless 不会仅仅因为一个缓存位于缓存目录里就删掉它。它先证明没有东西还需要它。

以 Gradle 为例。`~/.gradle/caches/8.12` 和 `~/.gradle/caches/8.14` 在结构上完全相同。磁盘上没有任何东西能说明哪个已经废弃。唯一的办法是读取机器上每一个真实项目：

- 向下遍历 `$HOME` 最多 5 层，跳过点目录和一个固定的跳过名单，并在第一个看起来像项目的目录停下：`.git`、`package.json`、`pubspec.yaml`、`gradlew`、`settings.gradle` 或 `settings.gradle.kts`（`src/core/verify/gradle.ts`、`src/core/verify/gradle.ts`）。
- 从每个项目根再向下遍历最多 12 层，读取 `gradle-wrapper.properties`、`gradle.properties`、`build.gradle`、`build.gradle.kts`（`src/core/verify/gradle.ts`）。
- 从 `distributionUrl` 里解析出版本号 —— `gradle-<version>-bin.zip` 或 `-all.zip`（`src/core/verify/gradle.ts`）。
- 跳过 vendored 副本 —— `build/`、`SourcePackages/`、`.dartServer/`、`node_modules/`、`.gradle/`、`.pub-cache/`、`DerivedData/`、`Pods/`、`ephemeral` —— 藏在这些目录里的 wrapper 永远不会被算作真实项目（`src/core/verify/gradle.ts`）。
- 如果还有任何项目锁定 8.12，该缓存被标记为 **BLOCKED** 并留在磁盘上。

遍历有边界：12 层，合计 200,000 个目录条目，所以不会失控扩张（`src/core/verify/gradle.ts`）。同样的思路驱动 `node_modules` 的 `git_clean`：进行中的操作（`MERGE_HEAD`、`CHERRY_PICK_HEAD`、`rebase-merge` 等）、未提交的改动或未推送的提交，都会让该目录不可删除（`src/core/verify/git.ts`、`src/core/verify/git.ts`）。

## 四个安全等级

| 等级 | 含义 | `apply` 的行为 |
| --- | --- | --- |
| 🟢 **GREEN** | 纯可重建缓存。若规则要求交叉验证，验证已通过。 | 你确认汇总后自动删除 |
| 🟡 **YELLOW** | 可能仍在使用中 —— VM 磁盘、模拟器 AVD、构建产物 —— 或因未达到 `minAgeDays` 而被降级的规则（`src/core/scan.ts`）。 | 逐条询问 |
| ⛔ **BLOCKED** | 规则要求验证，而验证失败（`src/core/scan.ts`）。记在 `totals.blocked` 下，且不计入 `reclaimable`（`src/core/scan.ts`）。 | **永不删除。** `--yes` 也不行，任何标志都不行 |
| 🔴 **RED** | 硬编码的受保护路径清单：Keychain、Mail、iCloud、`*-wal`/`*-shm`、`Preferences`、`.git`、Documents、Desktop、Pictures、Movies、Music、Contacts、Reminders、Calendar、Finance、Passes、Keynotes、Messages、`Application Support/com.apple.{Photos,MobileSync,Notes,Trial}`（`src/core/paths.ts`） | 永远不会成为 finding（`src/core/scan.ts`）。删除前会对解析后的真实路径再检查一次（`src/core/paths.ts`） |

BLOCKED 不是弱化版的 RED。RED 是一份静态路径清单，任何东西都删不掉它。BLOCKED 是一个实时判定：Dustless 试图证明某个缓存已无人使用，但没能证明。

### `apply` 采用 fail-closed

每一次删除都以 rule id 为键，而缺失的键会解析为 `skip`（`src/core/apply.ts`）：

```ts
const chosen = Boolean(opts.tiers && Object.hasOwn(opts.tiers, finding.ruleId));
const requested = chosen ? opts.tiers?.[finding.ruleId] ?? "skip" : "skip";
```

拼错的 id、payload 漏掉的 id、scan 根本没产出的 rule —— 全部解析为 skip，绝不会变成该规则自己的 tier。早期版本默认取规则自身的 tier，于是漏掉一个键就等于静默地说“删除”；那正是从一台真实机器上带走约 36 GB 的原因。

这个默认值是兜底，而不是机制。每个调用方都自己构造映射：CLI 从正在运行的 scan 构造（`src/cli/scan.ts`），MCP 从它事先校验过的 rule id 构造（`src/mcp/tools.ts`）。

### 为什么 BLOCKED 无法被覆盖

封锁在四个互相独立的位置被强制执行：scan 打上标记，apply 的汇总阶段把这些 finding 排除出待删集合（`src/cli/scan.ts`），`apply()` 在碰文件系统之前再查一次（`src/core/apply.ts`），MCP 安全层直接拒绝整个调用（`src/mcp/safety.ts`）。`--yes` 跳过的是提问。它无法伪造一次通过的验证，也无法解除封锁。RED 同理：它是一组编译进二进制文件的正则。没有任何标志、规则文件或 MCP 参数能触及它。

## 安装

### Release 二进制文件

推送一个 `v*` tag，build 工作流会编译四个目标并附到 release 上：`dustless-macos-arm64`、`dustless-macos-x64`、`dustless-linux-x64`、`dustless-windows-x64.exe`（`.github/workflows/release.yml`）。下载对应你机器的那个，放到 `PATH` 下的任意位置即可。Windows 还会得到 `Dustless-<version>-setup.exe`：一个按用户安装的安装程序，CI 会在附到 release 之前静默安装并卸载它进行验证。

```sh
dustless doctor     # 确认它能运行且能读取你的缓存
```

`doctor` 会打印平台、你的主目录、规则目录、规则数量、总容量和剩余容量，以及逐路径的可读性探测。当它需要的某个路径读不到时，退出码非零（`src/cli/doctor.ts`）。

**旧版本。** 0.3.0 及更早版本存在规则作用域缺陷：路径触及 `$HOME` 直接子目录的规则（最明显的就是 `~/*`）
可以用 `rule add` 创建，扫描该规则时会把 `$HOME` 的每个直接子目录都列为可回收。在 0.3.0 及更早版本上不要
用自定义规则执行清理。旧二进制文件原样保留在 releases 页面，历史不会被改写，v0.3.0 的 release notes 里
也有同样的警告。

### macOS 应用

同一个 release 里还有 `Dustless-<version>.dmg`。打开它，把 **Dustless** 拖进 `/Applications`。

这个 bundle 只做了 **ad hoc** 签名，因为项目没有 Apple Developer ID，所以 **没有** 公证（notarize）。
因此 macOS 会在首次启动时拦截并提示 *"Dustless can't be opened because Apple cannot check it for malicious
software"*。可以右键点击 app 选择 **Open** 再选一次 **Open**，或者清除隔离标记：

```sh
xattr -dr com.apple.quarantine "/Applications/Dustless.app"
```

**升级**：下载新的 `.dmg` 并替换 `/Applications` 里的 app。设置保存在
`~/Library/Preferences/dev.dustless.mac.plist`，规则保存在 `~/.config/dustless/rules.yaml`，两者都会保留。

**卸载**：把 `Dustless.app` 拖出 `/Applications` 并删除，菜单栏图标也会一起消失。如果你让 app 安装过
AirDrop 权限助手，请一并移除 - 在“网络”面板里有 **移除权限** 按钮，也可以自己删除
`/etc/sudoers.d/dustless-awdl`。

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

输入 `y` 然后回车继续。其他任何字符 —— 包括直接回车 —— 都会取消，且不删除任何东西。如果存在被封锁的 finding，汇总会另外说明有多少条目无论如何都无法删除（`src/cli/scan.ts`）。界面是越南语，因为二进制文件输出的就是越南语，所以这里原样保留。

**第 3 步 —— 回答黄色条目。** 每个 YELLOW 条目都会单独问你，一条一条：

```
🟡 YELLOW xóa 2.8 GB ở /Users/mac/Library/Android/sdk/ndk? [y/N]
```

`y` 删除该条目。其他任何字符都会跳过它并继续。没有任何东西会在你不知情的情况下被批量处理。

## 完全磁盘访问权限与无法扫描的规则

macOS 的 TCC 会对所有没有完全磁盘访问权限的进程隐藏某些目录，而且它的隐藏方式是让这些目录看起来是空的或不存在，而不是指出受保护的父目录。`dustless doctor` 正是为此探测 `~/Library/Mail`（`src/cli/doctor.ts`，`runDoctor`），并在探测返回 `EPERM` 或 `EACCES` 时**以 1 退出**。这是设计使然，不是崩溃：一个连自己的缓存都读不了的环境，不能信任它报告缓存里有什么，所以退出状态如实说明这一点。这也是为什么一次扫描可能发现比数据库更少的规则 —— 路径全都不可读的规则什么也贡献不了。

现在扫描会说明它没能看到什么，而不是保持沉默。`scan --json` 在 `findings` 和 `totals` 之外多带两个键（`src/types.ts`，`ScanReport`）：

- `unscannable` —— 每个未产出任何可扫描路径的规则一条记录，包含 `ruleId`、`tier`、`desc`、失败的 `pathPatterns`，以及 `reason`：`absent`（路径不存在）、`no_access`（EACCES/EPERM —— 通常是缺少完全磁盘访问权限）、`not_supported`（该规则在当前平台没有路径）、`red`（路径命中永久封锁清单）、`protected`（规则的路径范围触及 `$HOME`、它的父目录或文件系统根目录）或 `error`（`src/core/scan.ts`，`scan`）。
- `unscannableSummary` —— 每种 reason 的数量，六个键始终存在。

这些规则不计入 `totals`、`reclaimable` 和 `freed`：这个字段只会增加信息，绝不会增加数字。macOS 应用为这两个字段建模，并对 reason 的措辞做了本地化（`apps/dustless-mac/Sources/DustlessKit/Model/Reports.swift` 中的 `UnscannableRule`、`UnscannableSummary` 和 `UnscannableText`）。

## CLI 参考

下面每个命令都在 `src/cli.ts` 中实现。

| 命令 | 行为 |
| --- | --- |
| `dustless scan` | 交叉扫描所有规则，按大小排序列出 finding，并给出各等级汇总和可回收字节数。只读。 |
| `dustless apply` | Scan，打印汇总，询问 `Xóa? [y/N]`，然后删除 GREEN 并逐条询问 YELLOW。若有任何条目失败，退出码为 `1`。带 `--only-file <selection.json>` 时只删除该数组中的确切路径。 |
| `dustless rule list` | 打印规则数据库及其等级和描述，并说明加载来源。 |
| `dustless rule show <id>` | 以 JSON 打印单条规则。 |
| `dustless rule add <id> <green\|yellow> <desc> <download\|rebuild> <path> [path…]` | 以 `paths.all` 向 `~/.config/dustless/rules.yaml` 追加一条新规则。`<download\|rebuild>` 说明重新获取缓存的代价。 |
| `dustless rule validate [file]` | 解析并校验一个规则文件。省略路径则校验合并后的数据库。 |
| `dustless doctor` | 平台、主目录、配置目录、规则数量、总容量/剩余容量、关键路径可读性、Full Disk Access 检查。 |
| `dustless mcp` | 通过 stdio 提供 MCP 服务供 AI agent 使用。见 [docs/MCP.md](docs/MCP.md)。 |
| `dustless version` | 打印 `0.5.0`。`dustless help` 以及直接运行 `dustless` 都会打印用法。 |

### 标志

| 标志 | 作用 |
| --- | --- |
| `--json` | 为 `scan`、`apply`、`rule list`、`doctor`、`version` 在 stdout 输出一个 JSON 对象。对 `apply` 它同时意味着取消：没有 `--yes` 就没有提问，所以什么都不会删（`src/cli/scan.ts`）。 |
| `--quiet` | 抑制面向人类阅读的输出行。 |
| `--yes` | 跳过确认。既跳过汇总提问，**也**跳过每条 YELLOW 的提问。它不跳过验证，也无法解除 BLOCKED 或 RED。 |
| `--only-file <selection.json>` | 只应用这个 JSON 字符串数组中列出的绝对路径；其他所有 finding 都以未选中为由记为 `skipped`。省略它则 `apply` 保持原有行为。文件不可读、或不是字符串数组时，退出 `1` 且不删除任何东西。 |
| `--help` | 只要出现就打印用法说明 —— `dustless scan --help` 打印用法，不会执行 scan。直接运行 `dustless` 或 `dustless help` 输出相同内容。 |

### `apply --json`

`apply --json` 在 stdout 上恰好打印一个 JSON 对象，在每一条走到它的路径上 —— 已删除、无可删除、已取消 —— 键为 `outcomes`、`freed`、`freeBefore`、`freeAfter`、`elapsedMs`（`src/types.ts`）。`freed` 是 `max(0, freeAfter - freeBefore)`：整个卷上剩余空间的差值，不是被删条目之和，所以如果期间有别的东西占满了磁盘，一次真实删除之后它也可能读出 `0`（`src/core/apply.ts`）。

### 错误

每一个参数或校验错误 —— 未知命令、缺少取值的标志、无法解析的规则文件、不可用的 `--only-file` —— 都只有一种形态和一个退出状态：

| | stdout | stderr | exit |
| --- | --- | --- | --- |
| 带 `--json` | 一个 JSON 对象，`{"error":"…"}` | 空 | `1` |
| 不带 `--json` | 空 | `✖ …` | `1` |

`--quiet` 绝不吞掉错误：它只减少面向人类阅读的结果行，不会隐藏命令以非零退出的原因。缺失的值就是缺失，绝不会顺延到下一个标志：`dustless apps --uninstall --confirm` 是关于 `--uninstall` 的用法错误，而不是要卸载一个名为 `--confirm` 的应用。

## macOS app

`apps/dustless-mac` 是内嵌 Dustless 引擎的原生 SwiftUI 应用。支持 macOS 14+，作为普通应用运行 —— 有 Dock 图标、应用菜单栏、⌘Tab —— 并带一个主窗口和一个菜单栏项。设置 → 通用 → **在 Dock 中显示** 可以关掉 Dock 图标，切成纯菜单栏形态（`NSApp.setActivationPolicy`），启动时和运行时都即时生效。

**窗口** — `NavigationSplitView` 侧边栏 + 详情 (`DustlessApp.swift`)。侧边栏 (`SidebarView.swift`) 列出各个模块（Overview、Cleanup、Storage、Memory、Network），另有三个等级行 **GREEN**、**YELLOW**、**LOCKED**（BLOCKED）是进入 Cleanup 的快捷方式。引擎无法扫描的规则会被明确列出，而不是被计入总数。每个等级行显示数量与字节数。Cleanup 的详情视图 (`DetailView.swift`) 包含搜索/过滤框，**全部 / 无** 按钮（针对 GREEN 与 YELLOW），底部操作栏显示已选字节与 **复核并删除** (Cmd-Return)。LOCKED 条目会被列出但处于禁用状态，永不删除。一次扫描以空选择开始 —— 绝不预选任何内容。

**Finding 行** (`FindingRow.swift`) — 上下文菜单：**在访达中显示**、**复制路径**。

**确认弹窗** (`ConfirmDeleteSheet.swift`) — 列出每个已选项目的路径、规则 id、描述、大小，以及逐项的来源说明行（`note` 字段：例如 "rule requires ≥90 days, newest file is 0 days old" 或 "BLOCKED, pinned by /Users/x/repo"）。每行同样带上下文菜单。

**设置** (`SettingsView.swift`，通过工具栏齿轮图标或 Cmd-, 打开) — 语言 (vi/en/zh)、主题 (跟随系统/浅色/深色)、**在 Dock 中显示**（关闭 = 纯菜单栏：无 Dock 图标、无 ⌘Tab；`SettingsView.swift`）、**登录时启动**。语言、主题和 Dock 策略即时生效，无需重启。登录时启动放在设置里，不在侧边栏（依据 R8，`docs/RESEARCH-CLEANER-APPS.md:127-131`）。

**菜单栏弹出面板** (`MenuBarContent.swift`，由 `DustlessApp.swift` 以 `.menuBarExtraStyle(.window)` 呈现) — 上次扫描的来源信息（时间、规则数、耗时），一张实时网格（剩余空间、可回收字节、内存压力、网络接口/网关），上次读取失败时的数据过期警告，**立即扫描** / **复核并清理**，每个模块一行（Overview、Cleanup、Storage、Memory、Network），AirDrop (AWDL) 开关，以及 **打开 Dustless**、**设置**、**退出**。它打开时会通过 store 的过期窗口重新读取实时数字，绝不自行启动完整扫描。没有评分也没有圆环：未测量的值显示 `—`，扫描失败会如实说明，而不是把旧数字当当前值展示。

**键盘快捷键** (`DustlessApp.swift`、`DetailView.swift`) — Cmd-R：重新扫描；Cmd-1/2/3/4/5：Overview、Cleanup、Storage、Memory、Network；Cmd-,：设置；Cmd-Return：复核并删除。

**构建与运行** — `bun run build` 产出 `dist/dustless`（引擎）。随后 `bun run bundle:mac` 组装 `dist/Dustless.app`，引擎内嵌于 `Contents/Resources/dustless` (`scripts/bundle-macos.ts:7,33-35,51-59`)。脚本执行 `swift build -c release`，复制二进制与引擎，写入 `Info.plist`，并对 bundle 进行 ad-hoc 签名。最低 macOS 14.0 (`scripts/bundle-macos.ts`)。

**设计依据** — 以等级（而非工具链分类）为主导航轴，因为安全判定才是阻挡破坏性操作的闸门 (R1, `docs/RESEARCH-CLEANER-APPS.md:79-85`)。标题显示扫描的可回收总量；底部操作栏显示实时的 *已选* 总量 (R2)。被锁定条目获得完整视图并展示验证失败原因 (R3)。确认弹窗逐项给出决定性理由 (R5)。无预选 —— 设计上即 fail-closed (R4 第 3 点)。设置移出主导航 (R8)。

## AI agent / MCP

`dustless mcp` 通过 stdio 讲 MCP。完整文档、Claude Code / opencode / Cursor / VS Code 的客户端配置，以及一段完整的对话示例：**[docs/MCP.md](docs/MCP.md)**。五个工具：`scan`、`apply`、`list_rules`、`free_space`、`doctor`。

`apply` 上的那道闸门才是关键。没有 `confirm: true` 时，这次调用不删除任何东西，而是返回确切的计划（`src/mcp/safety.ts`）。正确顺序始终是：scan，把字节数展示给用户，得到一个明确的"是"，然后把完全相同的请求加上 `confirm: true` 再发一次。

agent 绝不能自作主张地设置 `confirm: true`。这里的判断标准不是"删掉它合不合理"，而是"一个人，此刻，是否读到了这个确切的字节数并说了是"。如果答案不是一次被记录下来的同意，这次调用就是一次空跑。

除此之外：RED 路径会拒绝整个调用，BLOCKED 条目会拒绝整个调用，未知的 rule id 会拒绝整个调用，超过 50 GB 的批次也会被拒绝，除非你同时传 `allow_large: true`（`src/mcp/safety.ts`）。apply 是全有或全无 —— 只要有一个问题，就什么都不删。

## 规则

内置数据库是 `src/core/default-rules.yaml`，自带 26 条规则，覆盖 Gradle、npm、pnpm、bun、uv、pub-cache、Homebrew、Yarn、pip、Go、Cargo、Brave、Chrome、Firefox、Edge、Puppeteer、Android、Colima、Docker，以及项目的 `node_modules`/`build` 产物。

把文件放在 `~/.config/dustless/rules.yaml`（或 `$XDG_CONFIG_HOME/dustless/rules.yaml`），它会覆盖式合并到内置数据库上：`id` 相同的规则**替换**原有规则，新的 `id` 则**追加**进去（`src/core/rules.ts`）。没有办法删除内置规则 —— 如果想让某条规则失效，就用一条什么都匹配不上的规则去替换它。

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
| `tier` | `green` 或 `yellow`。其他值在加载时被拒绝（`src/core/rules.ts`）。`red` 和 `blocked` 无法赋值：RED 是一份路径清单，BLOCKED 是一个判定。 |
| `desc` | 一行说明，显示在 `rule list` 中。 |
| `paths` | key 为 `mac`、`win`、`linux` 或 `all`（`src/core/rules.ts`）。`~` 展开为你的主目录；在 Windows 上 `%VAR%` 从环境变量展开（`src/core/paths.ts`）。每个值是一个字符串或字符串列表。`*` 匹配恰好一个路径段，也可以位于段内（`*.avd`）；一个 pattern 可以包含多个 `*`，每个都必须对上一个路径段：`~/*/*/node_modules` 匹配 `~/a/b/node_modules`，且不匹配别的。展开是有界的 —— 每个 pattern 最多 12 个路径段、20 000 个目录项 —— 触到任一边界的 pattern 会被报告为 unscannable，而不是被悄悄截断。pattern 不得触及 `$HOME`、`$HOME` 的父目录（包括 `~/..`）、文件系统根目录，也不得通过通配符选中 `$HOME` 的直接子目录：`~/*` 会被拒绝，`~/.cache/x` 不会（`src/core/paths.ts` 中的 `patternVerdict`）。 |
| `match` | 可选正则，作用于该 path 产生的每个目录的 basename（`src/core/paths.ts`）。 |
| `minAgeDays` | 如果其中最新的文件比这个时间更年轻，finding 会从 GREEN 降级为 YELLOW（`src/core/scan.ts`）。 |
| `requireVerify` | 一项交叉验证的名称：`gradle_version_unused`、`git_clean` 或 `not_in_gitignore`。若失败，finding 会降级为 YELLOW **并且**被标记为 BLOCKED（`src/core/scan.ts`）。 |
| `nativeCommand` | 可选。标明拥有该缓存的工具名。如果 `apply` 运行时该工具出现在进程表里，该缓存会被跳过，以免破坏正在进行的安装（`src/core/apply.ts`）。 |

按照 CONTRIBUTING 的说法，一条没有验证的新规则是 bug，不是功能；如果你无法验证它，就把它标为 `yellow`。信任它之前先校验：

```sh
dustless rule validate
dustless rule list
```

范围过宽的规则会被拒绝，绝不会被悄悄缩小。`dustless rule add` 以 `1` 退出且不写入任何内容，`dustless rule validate` 会指出出错规则的 id，而一次 scan 会把该规则报告为 unscannable，reason 为 `protected`，而不是删除任何东西。被拒绝的形态是：`$HOME` 本身、`$HOME` 的父目录（`~/..`）、文件系统根目录，以及任何可能落到 `$HOME` 直接子目录上的通配符 —— `~/*` 会把那些目录全部清空。只指名 `$HOME` 之下某一个目录的路径（`~/.cache/x`）仍被接受；`~/Documents` 之类依旧由红名单决定。

## 故障排查

**macOS：结果缺失，或 `doctor` 报 `EPERM`。**
TCC 在对进程隐藏目录。请在 系统设置 › 隐私与安全性 › 完全磁盘访问权限 中授权，然后退出并重新打开终端。`doctor` 会打印这个诊断，并在 `~/Library/Mail` 返回 `EPERM` 时以 `1` 退出（`src/cli/doctor.ts`）。注意这个陷阱：缺少授权会让 `~/Library/Caches` 看起来比实际*更小*，于是某些缓存根本不会出现在 scan 结果里。

**Windows：删除时报 `EBUSY` 或 `EPERM`。**
杀毒软件和 Windows 搜索索引器会持有短暂的锁。在 Windows 上 `remove()` 最多重试 4 次，采用指数退避，之后放弃（`src/core/apply.ts`）。关闭索引器或把该目录加入排除列表，然后重跑。

**什么都没有被删除。** 读 `detail` 列。常见原因，按你实际会遇到的顺序排列：
- 规则未达到 `minAgeDays`。一个 3 天大的 Android system image 配 `minAgeDays: 90`，成为 YELLOW 是设计如此，不是故障。
- 拥有它的工具正在运行。如果一条规则声明了 `nativeCommand` 且该工具出现在进程表里，它的缓存会被跳过，以免破坏正在进行的安装（`src/core/apply.ts`）。
- 验证失败。该条目是 BLOCKED，`--yes` 也无法改变。
- 路径命中红色清单、是 `$HOME` 或它的父目录、是文件系统根目录、或经过一个符号链接目录（`src/core/apply.ts`、`src/core/paths.ts`）。

**`apply` 取消了而什么也没删。** 没有 `--yes` 时它会先问，而且只在 stdin 是 TTY 时才问：在 CI 任务、管道或包装脚本里，它打印完汇总就停（`src/cli/scan.ts`）。带 `--json` 时同样如此，因为它无法提问。请在真正的终端里运行，或者改用 MCP server，它有自己显式的确认闸门。

**`freed` 显示 `0` 但文件确实被删了。** `freed` 是整个卷上剩余空间的变化量。如果运行期间有别的进程往磁盘写数据，这个差值会被压到 `0`（`src/core/apply.ts`）。请改看每条 outcome 的 `status`。

**我写的某条规则一直是 YELLOW。** 要么 `minAgeDays` 没达到，要么 `requireVerify` 正在失败。`scan` 会在路径下方的 `note` 列里打印原因。解决根本原因 —— 未提交的改动、某个项目仍然锁定的工具版本 —— 然后重新 scan。

## 参与贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [docs/TESTING.md](docs/TESTING.md)。`main` 受保护，对仓库所有者同样如此：无法直接 push，有一个必需的状态检查，历史必须线性，并且每次改动都需要 `@Dung-L3` 以 code owner 身份 review。Fork、建分支、提交、开 pull request。

黄金法则：**在写下证明规则安全的验证逻辑之前，不要往规则数据库里加清理规则。** 一条不检查还有没有人需要这些文件就直接删除的规则，是 bug，不是功能。

开 PR 之前：依次运行 `bun run typecheck`、`bun test`、`bun run build`。

## 许可证

MIT