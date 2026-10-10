# Dustless

[English](README.md) · [Tiếng Việt](README.vi.md) · [中文](README.zh.md)

**Disk cleanup for developer machines.** It measures every toolchain cache in its rule database, proves each one is unused by reading your real projects, and deletes only what passed.

Dustless is a single compiled binary for macOS, Windows and Linux. No runtime, no daemon, no admin rights.

---

## The problem

On a developer machine almost all reclaimable space sits in toolchain caches — Gradle, npm, pnpm, bun, uv, pub-cache, Cargo, Go modules, Android SDK images. General-purpose cleaners look somewhere else entirely: `~/Library/Caches`, system logs, `.DS_Store`, unused apps.

Measured on the reference machine (macOS, Bun 1.3.13, 2026-10-11): `du -sh ~/Library/Caches` reports **228 MB** — and even that is an undercount, since several cache subdirectories return `Operation not permitted` without Full Disk Access. Over the same period `dustless scan` reported **13.8 GB reclaimable** from the toolchain caches alone (`Thu hồi được 13.8 GB`). That is a 60x gap between where cleaners look and where the bytes are — and the directories holding the tens of gigabytes are exactly the ones a generic tool refuses to touch, because it cannot prove they are unused.

## How it differs: cross-scan before delete

Dustless does not delete a cache just because it sits in a cache directory. It first proves nothing still needs it.

Concretely, with Gradle. `~/.gradle/caches/8.12` and `~/.gradle/caches/8.14` are structurally identical. Nothing on disk says which one is dead. The only way to know is to read every real project on the machine:

- Walk `~/Innotech`, `~/Personal`, `~/Developer`, `~/Projects`, `~/repos` plus two levels of `$HOME` (`src/core/verify/gradle.ts:32`).
- Read `gradle-wrapper.properties`, `gradle.properties`, `build.gradle`, `build.gradle.kts` (`src/core/verify/gradle.ts:18`).
- Parse `distributionUrl` for `gradle-<version>-bin.zip` (`src/core/verify/gradle.ts:25`).
- Skip vendored copies so a wrapper buried in `build/`, `SourcePackages/`, `node_modules/`, `Pods/`, `DerivedData/` or `.gradle/` never counts as a real project (`src/core/verify/gradle.ts:6`).
- If any project still pins 8.12, that cache is reported **BLOCKED** and stays on disk.

The walk is bounded by a 200,000-entry budget so it cannot run away (`src/core/verify/gradle.ts:27`). The same idea drives `git_clean` for `node_modules`: an in-progress merge, an uncommitted change or an unpushed commit makes the directory non-deletable (`src/core/verify/git.ts:30`).

## The four safety levels

| Level | What it is | What `apply` does |
| --- | --- | --- |
| 🟢 **GREEN** | Pure regenerable cache. Cross-verification, where the rule requires it, passed. | Deletes automatically after the summary confirmation |
| 🟡 **YELLOW** | May still be in use — VM disks, emulator AVDs, build output. Also anything demoted for failing a check. | Asks about each item, one at a time |
| ⛔ **BLOCKED** | The rule required verification and verification failed. | **Never deleted.** Not by `--yes`, not by any flag |
| 🔴 **RED** | The hard-coded protected-path list: Keychain, Mail, iCloud, `*-wal`/`*-shm`, `Preferences`, `.git`, Documents, Desktop, Pictures, Movies, Music, Contacts, Reminders, Calendar, Finance, Messages (`src/core/paths.ts:81`) | Never becomes a finding. Re-checked again immediately before deletion |

### Why BLOCKED cannot be overridden

A previous version of this tool demoted a failed verification to YELLOW. A real incident followed: a `--yes` run deleted a Gradle cache that an active project was still using, and roughly 36 GB of the user's files went with it.

So the behaviour changed at the root. A finding whose verification failed sets a `blocked` flag, and that flag is checked at four independent points — the scan marks it, the apply summary excludes it, `apply()` re-checks it, and the MCP safety layer refuses the whole call. `--yes` skips the question. It cannot manufacture a passing verification, and it cannot clear the block. RED is the same: a regex list compiled into the binary. No flag, no rule file, no MCP parameter reaches it.

## Install

### Release binary

Push a `v*` tag and the build workflow compiles four targets and attaches them to the release: `dustless-macos` (Intel), `dustless-macos-arm64` (Apple Silicon), `dustless-windows.exe`, and `dustless-linux`. Download the one for your machine, drop it somewhere on your `PATH`, done.

```sh
dustless doctor     # confirm it runs and can read your caches
```

`doctor` needs no Full Disk Access. It prints the platform, the rules directory, the rule count, total and free bytes, and a per-path readability probe.

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

`scan` only reads. It cannot delete anything, whatever flags you give it.

**Step 2 — delete, after a summary.**

```sh
dustless apply
```

You will see this before anything is removed:

```
Sẽ xóa 4 mục tự động (5.8 GB)
Sẽ hỏi  2 mục (8.0 GB)
Tổng   13.8 GB

Xóa? [y/N]
```

Type `y` and press Enter to proceed. Anything else — including just pressing Enter — cancels and deletes nothing. The interface is Vietnamese because that is what the binary prints, which is why it is reproduced verbatim here.

**Step 3 — answer the yellow ones.** For each YELLOW item you get its own prompt, one at a time:

```
🟡 YELLOW xóa 5.3 GB ở /Users/mac/Library/Android/sdk/system-images? [y/N]
```

`y` deletes that item. Anything else skips it and moves on. Nothing is batched behind your back.

## CLI reference

Every command below is implemented in `src/cli.ts`.

| Command | Behaviour |
| --- | --- |
| `dustless scan` | Cross-scan every rule, print findings sorted by size, plus per-tier totals and reclaimable bytes. Read-only. |
| `dustless ui` | Start the local browser UI on 127.0.0.1 and open it. See [Web UI](#web-ui). |
| `dustless apply` | Scan, show the summary, ask `Xóa? [y/N]`, then delete GREEN and ask per YELLOW item. Exit code `1` if anything failed. |
| `dustless rule list` | Print the rule database with tiers and descriptions, and name the source it loaded from. |
| `dustless rule show <id>` | Print one rule as JSON. |
| `dustless rule add <id> <green\|yellow> <desc> <path> [path…]` | Append a new rule to `~/.config/dustless/rules.yaml` with `paths.all`. |
| `dustless rule validate [file]` | Parse and validate a rules file. Omit the path to validate the merged database. |
| `dustless doctor` | Platform, config dir, rule count, total/free bytes, readability of key paths, Full Disk Access check. |
| `dustless mcp` | Serve MCP over stdio for an AI agent. See [docs/MCP.md](docs/MCP.md). |
| `dustless version` | Print `0.1.0`. `dustless help` prints usage, and bare `dustless` also prints usage. |

### Flags

| Flag | Effect |
| --- | --- |
| `--json` | Machine-readable output on stdout for `scan`, `apply`, `rule list` and `doctor`. Also suppresses the interactive prompt. |
| `--quiet` | Suppress the human-readable lines. |
| `--yes` | Skip the confirmation. Skips the summary question **and** the per-item YELLOW questions. It does not skip verification, and it does not unblock BLOCKED or RED. |
| `--port <n>` | `ui` only. Port to listen on. Must be 1024-65535. Defaults to `4173`. |
| `--no-open` | `ui` only. Start the server without launching a browser. |
| `--help` | Usage. Accepted alongside any command. |

## Web UI

`dustless ui` starts a local server and opens the interface in your browser.

```sh
dustless ui                        # http://127.0.0.1:4173
dustless ui --port 8080            # pick your own port
dustless ui --no-open              # start without launching a browser
```

It binds **127.0.0.1 only** — never `0.0.0.0`, never a routable interface (`src/ui/server.ts:19`, `src/ui/server.ts:161`). Ports outside 1024-65535 are rejected before the socket opens, and if the port is already taken the server exits rather than silently listening somewhere else.

It also refuses by Host header: a request whose `Host` is not `127.0.0.1` or `localhost` gets `403` before routing runs (`src/ui/server.ts:103`, `src/ui/server.ts:122`). A strict CSP of `default-src 'none'; script-src 'self'` ships with every response (`src/ui/server.ts:24`).

Why this matters: the process has a `POST /api/apply` endpoint that deletes files on your disk. Anything that can reach the port can reach the delete endpoint. Loopback-only plus the Host check is what stands between a stray DNS rebind and a wiped home directory.

Routes: `GET /api/scan`, `GET /api/rules`, `GET /api/space`, `POST /api/apply`. `Ctrl+C` (or `SIGTERM`) shuts it down.

## AI agent / MCP

`dustless mcp` speaks MCP over stdio. Full documentation, client configs for Claude Code, opencode, Cursor and VS Code, and a worked conversation: **[docs/MCP.md](docs/MCP.md)**. Five tools: `scan`, `apply`, `list_rules`, `free_space`, `doctor`.

The `apply` gate is the part that matters. Without `confirm: true` the call deletes nothing and returns the exact plan instead (`src/mcp/safety.ts:43`). The correct sequence is always the same: scan, show the user the byte count, get an explicit yes, then re-send the identical request with `confirm: true`.

An agent must never set `confirm: true` on its own initiative. The argument is not "would deleting this be reasonable" — it is "did a human, just now, read this exact byte count and say yes". If the answer is not a recorded yes, the call is a dry run.

On top of that: RED paths refuse the whole call, BLOCKED findings refuse the whole call, an unknown rule id refuses the whole call, and anything above 50 GB refuses unless you also pass `allow_large: true` (`src/mcp/safety.ts:7`). Apply is all-or-nothing — one problem means nothing is deleted.

## Rules

The bundled database is `src/core/default-rules.yaml`. It ships 26 rules covering Gradle, npm, pnpm, bun, uv, pub-cache, Homebrew, Yarn, pip, Go, Cargo, Brave, Chrome, Firefox, Edge, Puppeteer, Android, Colima, Docker and project `node_modules`/`build` output.

Put a file at `~/.config/dustless/rules.yaml` (or `$XDG_CONFIG_HOME/dustless/rules.yaml`) and it is merged over the bundle: a rule with a matching `id` **replaces** the bundled one, and any id that is new is **added** (`src/core/rules.ts:18`). There is no way to remove a bundled rule — replace it with a rule that matches nothing if you want it inert.

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
| `tier` | `green` or `yellow`. Any other value is rejected at load (`src/core/rules.ts:56`). |
| `desc` | One line, shown in `rule list`. |
| `paths` | Keys are `mac`, `win`, `linux` or `all` (`src/core/rules.ts:7`). `~` expands to your home directory; on Windows `%VAR%` expands from the environment (`src/core/paths.ts:13`). Each value is a string or a list of strings. A `*` expands to the directories directly under its parent. |
| `match` | Optional regex tested against the basename of the directory being considered. |
| `minAgeDays` | If the newest file inside is younger than this, the finding is demoted from GREEN to YELLOW (`src/core/scan.ts:72`). |
| `requireVerify` | Name of a cross-check: `gradle_version_unused`, `git_clean`, or `not_in_gitignore`. If it fails, the finding is demoted to YELLOW **and** marked BLOCKED (`src/core/scan.ts:76`). |

Per CONTRIBUTING, a new rule without a verification is a bug, not a feature. If you cannot verify it, mark it `yellow`.

Validate before you trust it:

```sh
dustless rule validate
dustless rule list
```

## Troubleshooting

**macOS: results are missing or `doctor` reports `EPERM`.**
TCC is hiding directories from the process. Grant Full Disk Access in System Settings › Privacy & Security › Full Disk Access, then quit and reopen the terminal. `doctor` prints this diagnosis directly and exits non-zero (`src/cli.ts:214`). Note the trap: a missing grant makes `~/Library/Caches` look *smaller* than it is, so some caches never appear in a scan at all.

**Windows: `EBUSY` or `EPERM` on delete.**
Antivirus and the Windows Search indexer hold transient locks. `remove()` retries up to 4 attempts on Windows with exponential backoff, and gives up after that (`src/core/apply.ts:98`). Close the indexer or exclude the directory, then re-run.

**Nothing was deleted.** Read the `detail` column. The common causes, in the order you will hit them:
- A rule's `minAgeDays` is not met. A 3-day-old Android system image with `minAgeDays: 90` is YELLOW by design, not a failure.
- The tool is running. If `npm`, `npx`, `pnpm` or `yarn` is in the process table, its cache is skipped so it cannot break a live install (`src/core/apply.ts:9`).
- Verification failed. That item is BLOCKED and `--yes` will not change it.
- The path hit the red blocklist, is `$HOME` or a parent of it, or is the filesystem root (`src/core/apply.ts:86`).

**`apply` exits immediately.** If stdout is not a TTY — a CI job, a pipe, a wrapper script — `apply` refuses to prompt and deletes nothing (`src/cli.ts:130`). Run it in a real terminal. In automation, use the MCP server, which has its own explicit-confirmation gate.

**A rule I wrote stays YELLOW.** Either `minAgeDays` is not met, or `requireVerify` is failing. `scan` prints the reason under the path in the `note` column. Fix the underlying cause — an uncommitted change, a tool version a project still pins — then scan again.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). `main` is protected, including for the owner. Fork, branch, commit, open a pull request. No direct push is possible.

The golden rule: **do not add a cleanup rule to the rule database without writing the verification that proves it is safe.** A rule that deletes files without checking whether anyone still needs them is a bug, not a feature.

Before opening a PR: `bun run typecheck`, then `bun test`, then `bun run build`.

## License

MIT