# Dustless

[English](README.md) · [Tiếng Việt](README.vi.md) · [中文](README.zh.md)

**Disk cleanup for developer machines.** It measures every toolchain cache in its rule database, proves each one is unused by reading your real projects, and deletes only what passed.

Dustless is a single compiled binary for macOS, Windows and Linux. No runtime, no daemon, no admin rights. The version, 0.5.0, is read from `package.json` at build time (`src/cli/context.ts`) — one number, one source.

---

## The problem

On a developer machine almost all reclaimable space sits in toolchain caches — Gradle, npm, pnpm, bun, uv, pub-cache, Cargo, Go modules, Android SDK images. General-purpose cleaners look somewhere else entirely: `~/Library/Caches`, system logs, `.DS_Store`, unused apps.

Measured on the reference machine (macOS, Bun 1.3.13, 2026-10-11): `du -sh ~/Library/Caches` reports **213M** — and even that is an undercount, since several cache subdirectories return `Operation not permitted` without Full Disk Access. The same day, `dustless scan` reported **3.4 GB reclaimable** from the toolchain caches alone (`Thu hồi được 3.4 GB`). That is a 16x gap between where cleaners look and where the bytes are, and the directories holding the gigabytes are exactly the ones a generic tool refuses to touch, because it cannot prove they are unused. Both figures move with your caches; they are a snapshot of one machine on one day, not a benchmark.

## How it differs: cross-scan before delete

Dustless does not delete a cache just because it sits in a cache directory. It first proves nothing still needs it.

Concretely, with Gradle. `~/.gradle/caches/8.12` and `~/.gradle/caches/8.14` are structurally identical. Nothing on disk says which one is dead. The only way to know is to read every real project on the machine:

- Walk `$HOME` up to 5 levels, skipping dot-directories and a fixed skip list, and stop at the first directory that looks like a project: `.git`, `package.json`, `pubspec.yaml`, `gradlew`, `settings.gradle` or `settings.gradle.kts` (`src/core/verify/gradle.ts:31`, `src/core/verify/gradle.ts:61`).
- From each project root, walk up to 12 more levels and read `gradle-wrapper.properties`, `gradle.properties`, `build.gradle`, `build.gradle.kts` (`src/core/verify/gradle.ts:18`).
- Parse the version out of `distributionUrl` — `gradle-<version>-bin.zip` or `-all.zip` (`src/core/verify/gradle.ts:25`).
- Skip vendored copies — `build/`, `SourcePackages/`, `.dartServer/`, `node_modules/`, `.gradle/`, `.pub-cache/`, `DerivedData/`, `Pods/`, `ephemeral` — so a wrapper buried in one of them never counts as a real project (`src/core/verify/gradle.ts:6`).
- If any project still pins 8.12, that cache is reported **BLOCKED** and stays on disk.

The walk is bounded: 12 levels and 200,000 directory entries in total, so it cannot run away (`src/core/verify/gradle.ts:27`). The same idea drives `git_clean` for `node_modules`: an operation in progress (`MERGE_HEAD`, `CHERRY_PICK_HEAD`, `rebase-merge`, …), an uncommitted change or an unpushed commit makes the directory non-deletable (`src/core/verify/git.ts:11`, `src/core/verify/git.ts:30`).

## The four safety tiers

| Tier | What it is | What `apply` does |
| --- | --- | --- |
| 🟢 **GREEN** | Pure regenerable cache. Cross-verification, where the rule requires it, passed. | Deletes automatically, once you confirm the summary |
| 🟡 **YELLOW** | May still be in use — VM disks, emulator AVDs, build output — or a rule demoted because `minAgeDays` is not met (`src/core/scan.ts:132`). | Asks about each item, one at a time |
| ⛔ **BLOCKED** | The rule required verification and verification failed (`src/core/scan.ts:136`). Booked under `totals.blocked` and excluded from `reclaimable` (`src/core/scan.ts:200`). | **Never deleted.** Not by `--yes`, not by any flag |
| 🔴 **RED** | The hard-coded protected-path list: Keychain, Mail, iCloud, `*-wal`/`*-shm`, `Preferences`, `.git`, Documents, Desktop, Pictures, Movies, Music, Contacts, Reminders, Calendar, Finance, Passes, Keynotes, Messages, `Application Support/com.apple.{Photos,MobileSync,Notes,Trial}` (`src/core/paths.ts:97`) | Never becomes a finding (`src/core/scan.ts:87`). Rechecked against the resolved path immediately before deletion (`src/core/paths.ts:167`) |

BLOCKED is not a softer RED. RED is a static list of paths that can never be deleted by anything. BLOCKED is a live verdict: Dustless tried to prove a cache unused and could not.

### `apply` is fail-closed

Every deletion is keyed by rule id, and a key that is missing resolves to `skip` (`src/core/apply.ts:84`):

```ts
const chosen = Boolean(opts.tiers && Object.hasOwn(opts.tiers, finding.ruleId));
const requested = chosen ? opts.tiers?.[finding.ruleId] ?? "skip" : "skip";
```

A misspelled id, an id the payload forgot, a rule the scan never produced — all resolve to skip, never to the rule's own tier. An earlier version defaulted to the rule's tier instead, and an omitted key silently meant "delete"; that is what took roughly 36 GB off a real machine.

The default is the backstop, not the mechanism. Every caller builds its own map: the CLI from the live scan (`src/cli/scan.ts`), MCP from the rule ids it verified first (`src/mcp/tools.ts:189`).

### Why BLOCKED cannot be overridden

The block is enforced at four independent points: the scan sets the flag, the apply summary excludes those findings from the delete set (`src/cli/scan.ts`), `apply()` re-checks it before touching the filesystem (`src/core/apply.ts:63`), and the MCP safety layer refuses the whole call (`src/mcp/safety.ts:98`). `--yes` skips the question. It cannot manufacture a passing verification, and it cannot clear the block. RED is the same: a regex list compiled into the binary. No flag, no rule file, no MCP parameter reaches it.

## Install

### Release binary

Push a `v*` tag and the build workflow compiles four targets and attaches them to the release: `dustless-macos-arm64`, `dustless-macos-x64`, `dustless-linux-x64`, `dustless-windows-x64.exe` (`.github/workflows/release.yml:20-32`). Download the one for your machine, drop it somewhere on your `PATH`, done. Windows also gets `Dustless-<version>-setup.exe`, a per-user installer that is installed and uninstalled silently in CI before it is attached.

```sh
dustless doctor     # confirm it runs and can read your caches
```

`doctor` prints the platform, your home directory, the rules directory, the rule count, total and free bytes, and a readability probe for the key paths. It exits non-zero when a path it needs is unreadable (`src/cli/doctor.ts`).

### From source

Requires Bun 1.3 or newer.

```sh
git clone https://github.com/Dung-L3/dustless
cd dustless
bun install
bun run build          # writes dist/dustless
./dist/dustless scan
```

You can also run the TypeScript entrypoint directly, without building: `bun src/cli.ts scan`.

## Quick start

If you have never used a terminal tool before, do exactly this.

**Step 1 — look, delete nothing.**

```sh
dustless scan
```

Real output on the reference machine:

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

`scan` only reads. It cannot delete anything, whatever flags you give it.

**Step 2 — delete, after a summary.**

```sh
dustless apply
```

You will see this before anything is removed — including before any GREEN item:

```
Sẽ xóa 3 mục tự động (611.4 MB)
Sẽ hỏi  3 mục (2.8 GB)
Tổng   3.4 GB
Xóa? [y/N]
```

Type `y` and press Enter to proceed. Anything else — including just pressing Enter — cancels and deletes nothing. If there are blocked findings, the summary also states how many items can never be deleted, whatever you answer (`src/cli/scan.ts`). The interface is Vietnamese because that is what the binary prints, which is why it is reproduced verbatim here.

**Step 3 — answer the yellow ones.** For each YELLOW item you get its own prompt, one at a time:

```
🟡 YELLOW xóa 2.8 GB ở /Users/mac/Library/Android/sdk/ndk? [y/N]
```

`y` deletes that item. Anything else skips it and moves on. Nothing is batched behind your back.

## Full Disk Access and unscannable rules

macOS TCC hides some directories from any process that lacks Full Disk Access, and it hides them by
making them look empty or absent rather than by naming the protected parent. `dustless doctor` probes
`~/Library/Mail` for exactly that (`src/cli/doctor.ts`, `runDoctor`) and **exits 1 when the probe
comes back `EPERM` or `EACCES`**. That is by design, not a crash: an environment that cannot read its
own caches cannot be trusted to report what is in them, so the exit status says so. It is also why a
scan can find fewer rules than the database holds — a rule whose paths are all unreadable contributes
nothing.

A scan now says what it could not look at instead of staying silent. `scan --json` carries two extra
keys beside `findings` and `totals` (`src/types.ts`, `ScanReport`):

- `unscannable` — one entry per rule that produced no scannable path, each with `ruleId`, `tier`,
  `desc`, the `pathPatterns` that failed, and a `reason` of `absent` (the path does not exist),
  `no_access` (EACCES/EPERM — usually the missing Full Disk Access), `not_supported` (the rule has no
  path for this platform), `red` (the path matched the permanent blocklist) or `error`
  (`src/core/scan.ts`, `scan`).
- `unscannableSummary` — the count per reason, with all five keys always present.

Those rules are excluded from `totals`, `reclaimable` and `freed`: the field can only ever add
information, never a number. The macOS app models both fields and localizes the reason wording
(`UnscannableRule`, `UnscannableSummary` and `UnscannableText` in
`apps/dustless-mac/Sources/DustlessKit/Model/Reports.swift`).

## CLI reference

Every command below is implemented in `src/cli.ts`.

| Command | Behaviour |
| --- | --- |
| `dustless scan` | Cross-scan every rule, print findings sorted by size, plus per-tier totals and reclaimable bytes. Read-only. |
| `dustless apply` | Scan, print the summary, ask `Xóa? [y/N]`, then delete GREEN and ask per YELLOW item. Exit code `1` if anything failed. With `--only-file <selection.json>` it deletes only the exact paths in that array. |
| `dustless rule list` | Print the rule database with tiers and descriptions, and name the source it loaded from. |
| `dustless rule show <id>` | Print one rule as JSON. |
| `dustless rule add <id> <green\|yellow> <desc> <path> [path…]` | Append a new rule to `~/.config/dustless/rules.yaml` with `paths.all`. |
| `dustless rule validate [file]` | Parse and validate a rules file. Omit the path to validate the merged database. |
| `dustless doctor` | Platform, home, config dir, rule count, total/free bytes, readability of key paths, Full Disk Access check. |
| `dustless mcp` | Serve MCP over stdio for an AI agent. See [docs/MCP.md](docs/MCP.md). |
| `dustless version` | Print `0.5.0`. `dustless help`, and a bare `dustless`, print usage. |

### Flags

| Flag | Effect |
| --- | --- |
| `--json` | One JSON object on stdout for `scan`, `apply`, `rule list`, `doctor`, `version`. For `apply` it also cancels: with no `--yes` there is no prompt, so nothing is deleted (`src/cli/scan.ts`). |
| `--quiet` | Suppress the human-readable lines. |
| `--yes` | Skip the confirmation. Skips the summary question **and** the per-item YELLOW questions. It does not skip verification, and it does not unblock BLOCKED or RED. |
| `--only-file <selection.json>` | Apply only the exact paths in this JSON array of absolute paths; every other finding is `skipped` as not selected. Omit it and `apply` keeps its behaviour of offering every green/yellow finding. An unreadable file, or one that is not an array of strings, exits `1` and deletes nothing. |
| `--help` | Usage, printed whenever it appears — `dustless scan --help` prints usage, not a scan. A bare `dustless` or `dustless help` prints the same. |

### `apply --json`

`apply --json` prints exactly one JSON object on stdout, on every path that reaches it — deleted, nothing deletable, cancelled — with the keys `outcomes`, `freed`, `freeBefore`, `freeAfter`, `elapsedMs` (`src/types.ts:72`). `freed` is `max(0, freeAfter - freeBefore)`: a delta of free space on the volume, not a sum of the deleted items, so it can read `0` after a real deletion if something else filled the disk in between (`src/core/apply.ts:35`).

### Errors

Every argument or validation error — an unknown command, a flag with no value, a rules file that does not parse, an unusable `--only-file` — has one shape and one exit status:

| | stdout | stderr | exit |
| --- | --- | --- | --- |
| with `--json` | one JSON object, `{"error":"…"}` | empty | `1` |
| without `--json` | empty | `✖ …` | `1` |

`--quiet` never suppresses an error: it reduces the human-readable result lines, not the reason a command exited non-zero. A value that is missing is missing, never the next flag: `dustless apps --uninstall --confirm` is a usage error about `--uninstall`, not a request to uninstall an app named `--confirm`.

## macOS app

`apps/dustless-mac` is a native SwiftUI app that embeds the Dustless engine. It runs on macOS 14+ as a normal app — Dock icon, app menu bar, ⌘Tab — with a main window and a menu-bar item. Settings → General → **Show in Dock** turns the Dock icon off for a menu-bar-only shape (`NSApp.setActivationPolicy`), applied at launch and live.

**Window** — `NavigationSplitView` sidebar + detail (`DustlessApp.swift:161-167`). The sidebar (`SidebarView.swift`) lists the modules (Overview, Cleanup, Storage, Memory, Network) and, under **Cleanup**, three tier rows: **GREEN**, **YELLOW**, **LOCKED** (BLOCKED). Each tier row shows count and bytes. The Cleanup detail view (`DetailView.swift`) has a search/filter field, **All / None** buttons for GREEN and YELLOW, and a bottom action bar with selected bytes and **Review & Delete** (Cmd-Return). LOCKED items are listed but disabled and never deleted. A scan starts with an empty selection — nothing is pre-selected.

**Finding row** (`FindingRow.swift:86`) — context menu: **Reveal in Finder**, **Copy Path**.

**Confirm sheet** (`ConfirmDeleteSheet.swift:17-63`) — lists every selected item with path, rule id, description, size, and a per-item provenance line (the `note` field: e.g. "rule requires ≥90 days, newest file is 0 days old" or "BLOCKED, pinned by /Users/x/repo"). Same context menu on each row.

**Settings** (`SettingsView.swift`, opened via toolbar gear or Cmd-,) — Language (vi/en/zh), Theme (System/Light/Dark), **Show in Dock** (off = menu-bar-only: no Dock icon, no ⌘Tab; `SettingsView.swift:28`), **Launch at login**. Language, theme and the Dock policy apply live, no relaunch. Launch at login lives in Settings, not the sidebar (per R8 in `docs/RESEARCH-CLEANER-APPS.md:127-131`).

**Menu bar popover** (`MenuBarContent.swift`, presented by `DustlessApp.swift` with `.menuBarExtraStyle(.window)`) — the last scan's provenance (age, rules, duration), a live grid of free space, reclaimable bytes, memory pressure and network interface/gateway, a stale-scan warning when the last read failed, **Scan now** / **Review & Clean**, a row per module (Overview, Cleanup, Storage, Memory, Network), the AirDrop (AWDL) toggle, and **Open Dustless**, **Settings**, **Quit**. It re-reads the live numbers when it opens, through the store's staleness windows, and never starts a full scan on its own. No score and no ring: an unmeasured value shows `—`, and a failed scan says so rather than presenting old numbers as current.

**Keyboard shortcuts** (`DustlessApp.swift:28-40`, `DetailView.swift:206`) — Cmd-R: rescan; Cmd-1/2/3/4/5: Overview, Cleanup, Storage, Memory, Network; Cmd-,: Settings; Cmd-Return: Review & Delete.

**Build & run** — `bun run build` produces `dist/dustless` (the engine). Then `bun run bundle:mac` assembles `dist/Dustless.app` with the engine embedded at `Contents/Resources/dustless` (`scripts/bundle-macos.ts:7,33-35,51-59`). The script runs `swift build -c release`, copies the binary and engine, writes `Info.plist`, and ad-hoc signs the bundle. Minimum macOS 14.0 (`scripts/bundle-macos.ts:24`).

**Design rationale** — The tier axis (not toolchain category) is the primary navigation because the safety verdict gates the destructive act (R1, `docs/RESEARCH-CLEANER-APPS.md:79-85`). The header shows the scan's total reclaimable bytes; the action bar shows the live *selected* total (R2). Locked items get a full view with the failed verification reason (R3). The confirm sheet shows the deciding reason per item (R5). No pre-selection — fail-closed by design (R4 item 3). Settings off the main nav (R8).

## AI agent / MCP

`dustless mcp` speaks MCP over stdio. Full documentation, client configs for Claude Code, opencode, Cursor and VS Code, and a worked conversation: **[docs/MCP.md](docs/MCP.md)**. Five tools: `scan`, `apply`, `list_rules`, `free_space`, `doctor`.

The `apply` gate is the part that matters. Without `confirm: true` the call deletes nothing and returns the exact plan instead (`src/mcp/safety.ts:43`). The correct sequence is always the same: scan, show the user the byte count, get an explicit yes, then re-send the identical request with `confirm: true`.

An agent must never set `confirm: true` on its own initiative. The argument is not "would deleting this be reasonable" — it is "did a human, just now, read this exact byte count and say yes". If the answer is not a recorded yes, the call is a dry run.

On top of that: RED paths refuse the whole call, BLOCKED findings refuse the whole call, an unknown rule id refuses the whole call, and anything above 50 GB refuses unless you also pass `allow_large: true` (`src/mcp/safety.ts:7`). Apply is all-or-nothing — one problem means nothing is deleted.

## Rules

The bundled database is `src/core/default-rules.yaml`. It ships 26 rules covering Gradle, npm, pnpm, bun, uv, pub-cache, Homebrew, Yarn, pip, Go, Cargo, Brave, Chrome, Firefox, Edge, Puppeteer, Android, Colima, Docker and project `node_modules`/`build` output.

Put a file at `~/.config/dustless/rules.yaml` (or `$XDG_CONFIG_HOME/dustless/rules.yaml`) and it is merged over the bundle: a rule with a matching `id` **replaces** the bundled one, and any id that is new is **added** (`src/core/rules.ts:28`). There is no way to remove a bundled rule — replace it with a rule that matches nothing if you want it inert.

A real rule:

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

| Field | Meaning |
| --- | --- |
| `id` | Unique. Replaces a bundled rule with the same id. |
| `tier` | `green` or `yellow`. Any other value is rejected at load (`src/core/rules.ts:60`). `red` and `blocked` are not assignable: RED is a path list, BLOCKED is a verdict. |
| `desc` | One line, shown in `rule list`. |
| `paths` | Keys are `mac`, `win`, `linux` or `all` (`src/core/rules.ts:7`). `~` expands to your home directory; on Windows `%VAR%` expands from the environment (`src/core/paths.ts:14`). Each value is a string or a list of strings. A `*` expands to the directories directly under its parent. |
| `match` | Optional regex tested against the basename of each directory the path produced (`src/core/paths.ts:90`). |
| `minAgeDays` | If the newest file inside is younger than this, the finding is demoted from GREEN to YELLOW (`src/core/scan.ts:132`). |
| `requireVerify` | Name of a cross-check: `gradle_version_unused`, `git_clean`, or `not_in_gitignore`. If it fails, the finding is demoted to YELLOW **and** marked BLOCKED (`src/core/scan.ts:136`). |
| `nativeCommand` | Optional. Names the tool that owns the cache. If that tool is in the process table when `apply` runs, the cache is skipped so a live install is not broken underneath you (`src/core/apply.ts:72`). |

Per CONTRIBUTING, a new rule without a verification is a bug, not a feature; if you cannot verify it, mark it `yellow`. Validate before you trust it:

```sh
dustless rule validate
dustless rule list
```

## Troubleshooting

**macOS: results are missing or `doctor` reports `EPERM`.**
TCC is hiding directories from the process. Grant Full Disk Access in System Settings › Privacy & Security › Full Disk Access, then quit and reopen the terminal. `doctor` prints this diagnosis and exits `1` when `~/Library/Mail` comes back `EPERM` (`src/cli/doctor.ts`). Note the trap: a missing grant makes `~/Library/Caches` look *smaller* than it is, so some caches never appear in a scan at all.

**Windows: `EBUSY` or `EPERM` on delete.**
Antivirus and the Windows Search indexer hold transient locks. `remove()` retries up to 4 attempts on Windows with exponential backoff, and gives up after that (`src/core/apply.ts:118`). Close the indexer or exclude the directory, then re-run.

**Nothing was deleted.** Read the `detail` column. The common causes, in the order you will hit them:
- The rule's `minAgeDays` is not met. A 3-day-old Android system image with `minAgeDays: 90` is YELLOW by design, not a failure.
- The owning tool is running. If a rule declares `nativeCommand` and that tool is in the process table, its cache is skipped so it cannot break a live install (`src/core/apply.ts:73`).
- Verification failed. That item is BLOCKED and `--yes` will not change it.
- The path hit the red blocklist, is `$HOME` or a parent of it, is the filesystem root, or is reached through a symlinked directory (`src/core/apply.ts:104`, `src/core/paths.ts:167`).

**`apply` cancels without deleting anything.** With no `--yes` it asks first, and it only asks on a TTY stdin: in a CI job, a pipe or a wrapper script it prints the summary and stops (`src/cli/scan.ts`). The same happens with `--json`, which cannot prompt. Run it in a real terminal, or use the MCP server, which has its own explicit-confirmation gate.

**`freed` says `0` but files were deleted.** `freed` is the change in free space on the whole volume. If another process wrote to the disk during the run, the delta clamps to `0` (`src/core/apply.ts:35`). Read the per-outcome `status` instead.

**A rule I wrote stays YELLOW.** Either `minAgeDays` is not met, or `requireVerify` is failing. `scan` prints the reason under the path in the `note` column. Fix the underlying cause — an uncommitted change, a tool version a project still pins — then scan again.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/TESTING.md](docs/TESTING.md). `main` is protected, including for the owner: no direct push, one required status check, linear history, and `@Dung-L3` code-owner review on every change. Fork, branch, commit, open a pull request.

The golden rule: **do not add a cleanup rule to the rule database without writing the verification that proves it is safe.** A rule that deletes files without checking whether anyone still needs them is a bug, not a feature.

Before opening a PR: `bun run typecheck`, then `bun test`, then `bun run build`.

## License

MIT