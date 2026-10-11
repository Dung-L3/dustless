# Testing

```sh
bun run typecheck     # tsc --noEmit over src and tests
bun test              # everything: 182 tests, about 6s on a laptop
bun run test:ui       # just the web-UI suite in tests/e2e-ui
```

No build step and no browser is needed for the UI suite. `tests/e2e` runs the compiled binary in
`dist/`, and `tests/e2e/cli.test.ts:23` builds it itself before the first assertion, so you do not
have to remember `bun run build` first.

## Browser-driven UI testing is deliberately not automated

Do not add a suite that launches a browser. It was tried once and it is not coming back.

Driving Brave headless over the DevTools Protocol means launching it with a fresh `--user-data-dir`.
On macOS, a Chromium-family browser with a new profile directory has no key for the `Brave Safe
Storage` keychain item, so it generates one — which makes macOS show:

> Brave Browser wants to access key "Brave Safe Storage" in your keychain

That prompt is about **your real login keychain**, and the first time someone sees it they reasonably
conclude their keys are about to be lost. It is not a test problem you can configure around; it is
the browser asking for a credential that belongs to the person sitting at the machine.

So: no browser binaries, no Playwright/Puppeteer/Selenium/WebDriver, no `open`, no `webbrowser`, no
`osascript`, no `--user-data-dir` or any other browser flag, and no touching `security` or the login
keychain. If you think a check needs a browser, skip it and write it down in
`tests/e2e-ui/REPORT.md` under "Not testable without a browser". A skipped check is fine. A keychain
prompt is not.

`tests/e2e-ui/` therefore tests the logic, not the pixels: the `i18n.js` tables directly, `app.js`
against a hand-written DOM stub, `index.html` and `style.css` as text, and the HTTP API against a
real server. If you want to look at the page yourself, run `bun src/cli.ts ui` and open the URL it
prints.

## The sandbox rule

**Anything that can delete must run in a child process whose environment carries `HOME` pointing at
a throwaway directory.** Both harnesses do it. `tests/e2e-ui/harness.ts` `mkdtemp`s a root, `mkdir
home`, plants files, spawns `bun src/cli.ts ui --port N --no-open` with `HOME` and `XDG_CONFIG_HOME`
in the child's env, and `rm -rf`s the root afterwards. `tests/e2e/harness.ts` does the same for the
compiled binary, and additionally refuses a `HOME` that is not under the OS temp directory.

The in-process version does not work, and this is not a theoretical warning:

```ts
process.env.HOME = "/tmp/fake";
const { scan } = await import("../src/core/scan.ts");   // scan/apply use the real /Users/mac
```

`os.homedir()` in Bun does not re-read `$HOME` after startup, and `src/core/paths.ts` captures
`export const HOME = homedir()` once at module load. Import the scanner into a process that has
already resolved its home and you are deleting the user's real caches. Verified:

| How `HOME` is set | `os.homedir()` returns |
| --- | --- |
| `process.env.HOME = x` in the running process | the real home |
| `HOME=x` in a spawned child's env | `x` |

Re-check both rows in five seconds whenever you touch the harness:

```sh
echo 'console.log(require("os").homedir())' > /tmp/hd.js && HOME=/tmp/fake bun /tmp/hd.js   # /tmp/fake
echo 'process.env.HOME="/tmp/fake";console.log(require("os").homedir())' > /tmp/hd2.js && bun /tmp/hd2.js  # the real home
```

The sandbox helper is not optional either. `tests/e2e/harness.ts` checks every invocation before it
happens: `assertTempRoot()` refuses a `HOME` that is not under the OS temp directory and refuses
`/Users/mac` outright, and `assertSandboxed()` refuses any absolute path argument that escapes the
sandbox. `tests/e2e-ui/harness.ts` exports `assertInsideSandbox()`, which asserts that every path a
scan returned is strictly under the sandbox root (`tests/e2e-ui/server.test.ts:200`).

## Writing tests for the UI

- `dom-stub.ts` parses `index.html` and implements the slice of the DOM that `app.js` touches. It
  parses the real page, so a renamed id surfaces as a `missing` entry and a crash, not as a silently
  skipped check.
- `installDom()` replaces `document`, `fetch`, `matchMedia`, `localStorage` and the animation frame
  callback on `globalThis`. Bun runs every test file in one process, so **call `stub.restore()` in
  an `afterAll`** or the next file inherits your stub and hangs. Wrapping the global `setTimeout` or
  `setInterval` also breaks `node:net` inside `bun test`; leave the timers alone.
- `app.js` exports nothing and runs `runScan()` at import. The test imports it dynamically after the
  globals are installed, and drives it through the DOM. To test another scenario, swap the
  responder with `stub.respond()` and click `#scanBtn` rather than re-importing.
- Tests that assert on a rendered number should parse the rendered text back into bytes. A number
  that formats correctly is not the same as a number that is correct.

## What is expected to fail right now

Nothing, in `tests/e2e-ui`: `bun run test:ui` is **69 pass, 0 fail** across four files as of the
documentation audit below. `tests/e2e-ui/REPORT.md` still describes 60 pass / 9 fail and lists nine
product defects — those nine were real, and they were fixed (the UI stopped selling blocked findings
for deletion, `POST /api/apply` stopped accepting a cross-origin write, and an oversized body now
answers `413` instead of a bare `200`). The report is kept as the record of what those defects were,
not as a status page. Re-run `bun run test:ui` before believing either document.

Three checks in the full suite are worth knowing about before you file a bug against them. All three
assert on `freed`, which is `max(0, freeAfter - freeBefore)` — the change in free space on the **whole
volume** (`src/core/apply.ts:33`), not a sum of the deleted items. When the rest of the suite is
planting and deleting hundreds of megabytes at the same time, that delta moves on its own:

- `tests/core.test.ts` "reports actual freed bytes, not the estimate" expects `freed > 0` after a real
  16 MB deletion, and fails when another test consumed the space in between.
- `tests/e2e/outputs.test.ts` "apply --json reports outcomes and freed bytes" expects `freed > 0` for
  the same reason.
- `tests/e2e-ui/server.test.ts` "an all-skip payload deletes nothing and frees nothing" expects
  `freed === 0`, and fails when another test released space in between.

Measured on the reference machine over six full `bun test` runs: between 0 and 2 failures, always
from that list, and never the same pair twice. They pass consistently when their own file is run
alone. If you touch `freed`, assert on the per-outcome `status` instead, or take the delta against a
filesystem the test owns.

## Documentation audit

Run on branch `docs/accuracy`, 2026-10-11, against `main` at `cf2f23f`. Every claim below was checked
against the source at the cited line; markdown only was touched.

### Inaccuracies found and how they were resolved

| # | Claim | Reality | Fix |
| --- | --- | --- | --- |
| 1 | Every README: "Walk `~/Innotech`, `~/Personal`, `~/Developer`, `~/Projects`, `~/repos` plus two levels of `$HOME` (`gradle.ts:32`)" | No such root list exists. `gradle.ts:32` is `PROJECT_MARKERS`. `discoverProjectRoots()` walks `$HOME` at most 5 levels deep and stops at the first directory holding a project marker (`gradle.ts:61`) | Replaced with the real mechanism, cited per line, in all three READMEs |
| 2 | Every README: "`du -sh ~/Library/Caches` reports 228 MB … 13.8 GB reclaimable … a 60x gap" | Re-measured on the reference machine: `213M` and `3.4 GB`, a 16x gap | Re-measured read-only and restated as a dated snapshot, not a benchmark |
| 3 | Every README: the Gradle section cited `gradle.ts:6` for vendored dirs and listed six of them | The set has nine (`gradle.ts:6`): `build`, `SourcePackages`, `.dartServer`, `node_modules`, `.gradle`, `.pub-cache`, `DerivedData`, `Pods`, `ephemeral` | All nine listed, with the depth and entry budget stated |
| 4 | Every README: "`dustless version` prints `0.1.0`" | `package.json` is `0.1.2`; `cli.ts:3` imports it at build time | Now `0.1.2`, with the single source of truth named |
| 5 | Every README: "`--help` — usage, accepted alongside any command" | `cli.ts:270`–`cli.ts:286` dispatch the command first, so `dustless scan --help` runs a scan and `dustless rule list --help` lists rules. `--version` prints usage, not a version | Corrected, and both behaviours stated |
| 6 | Every README: YELLOW is "anything demoted for failing a check" | A failed verification demotes to yellow **and** sets `blocked` (`scan.ts:76`), and `tally()` books it under `totals.blocked`, never green/yellow (`scan.ts:131`) | Split: `minAgeDays` → yellow; `requireVerify` → yellow + BLOCKED, counted separately, excluded from `reclaimable` |
| 7 | Every README: "An earlier version demoted a failed verification to YELLOW" as the cause of the 36 GB loss | The actual root cause was fail-open resolution: an absent rule id defaulted to the rule's tier, so a forgotten key meant delete. Fixed in `e44c8ca` | Rewritten around `apply.ts:71`, with the fail-closed default documented as the headline property |
| 8 | Every README: `apply` needed no documentation of what happens with `--json` and no prompt | `cli.ts:148` returns false for `--json`, so `apply --json` without `--yes` cancels and deletes nothing | Documented, plus the exact `ApplyReport` keys and the one hard-error exit path |
| 9 | Every README: UI security cited `server.ts:161` for the loopback bind and `server.ts:103`/`:122` for the Host check | Line 161 is the `Content-Type` test; the bind is `server.ts:200` and the Host check is `server.ts:116`/`:147` | Citations corrected, and the `Origin` → 403 and `Content-Type` → 415 checks added — they are the reason a random page cannot POST a delete |
| 10 | Every README: "if the port is already taken the server exits rather than silently listening somewhere else" | True for the CLI, but the reason is non-obvious: `startServer` only falls back to 4477/ephemeral when called with no port, which the CLI never does (`server.ts:223`) | Rewritten to say why |
| 11 | Every README: release artifacts named `dustless-macos`, `dustless-macos-arm64`, `dustless-windows.exe`, `dustless-linux` | `.github/workflows/release.yml:21` produces `dustless-macos-arm64`, `dustless-macos-x64`, `dustless-linux-x64`, `dustless-windows-x64.exe` | Corrected names |
| 12 | Every README: "If `npm`, `npx`, `pnpm` or `yarn` is in the process table, its cache is skipped" | The check is driven by a rule's `nativeCommand` (`apply.ts:65`); `yarn.cache` declares none, so yarn never triggers it | Rewritten as "a rule that declares `nativeCommand`", and `nativeCommand` added to the rule field table |
| 13 | Every README: `doctor` Full Disk Access check cited `cli.ts:214`; the non-TTY `apply` check cited `cli.ts:130` | The FDA check is `cli.ts:259` and it tests **stdin**, not stdout (`cli.ts:157`) | Citations and the stdin/stdout distinction corrected |
| 14 | Every README: no mention of `nativeCommand` in the rule field table | It is a real field with real behaviour | Added to the table |
| 15 | This file: "Nine checks in `tests/e2e-ui` fail against the current product" | `bun run test:ui` is 69 pass / 0 fail. The nine were fixed | Replaced with the measured state and the stale `REPORT.md` called out by name |
| 16 | This file: "run `bun run build` first if you have never built" | `tests/e2e/cli.test.ts:23` builds the binary itself | Corrected |
| 17 | This file: "bun test — everything, about 10s" | 182 tests in 5.5–6s | Corrected, with the count |
| 18 | This file: "`assertInsideSandbox()` … every finding path goes through it before any apply" | It is called on the findings of one test (`server.test.ts:200`); the per-invocation guards live in `tests/e2e/harness.ts` (`assertTempRoot`, `assertSandboxed`) | Rewritten to name which guard does what |
| 19 | `docs/MCP.md`: opencode servers configured under `mcp.servers` | In opencode v2 the `mcp` key **is** the map. Verified against opencode v2.0.26: the nested form reports "No MCP servers configured"; the flat form loads | Both opencode snippets flattened |
| 20 | `docs/MCP.md`: permissions example used `{action, resource, effect}` and `dustless_*` | opencode's `permission` is keyed by tool name with `ask`/`allow`/`deny`; MCP tools are registered as `<server>_<tool>` | Rewritten against the published schema, with `tools` as the hard-off switch |
| 21 | `docs/MCP.md`: the worked conversation sent `confirm: true` in the request whose response said "`confirm` is not exactly true" | Self-contradictory | The first call is now the dry run it claims to be, and the narration matches the JSON |
| 22 | `CONTRIBUTING.md`: "a rule that only runs on one OS will be rejected" | `defect()` checks for an unknown platform key, an empty value, a missing `paths`/`id`/`desc` and a tier outside `green|yellow` — a mac-only rule is valid (`rules.ts:53`) | Rewritten to list exactly what is rejected and what is not |
| 23 | `CONTRIBUTING.md`: "deleting a user-created directory → `red`" | `red` is not an assignable tier; it is a path list in `src/core/paths.ts:81` | Corrected, with a pointer to where that rule lives |
| 24 | `CONTRIBUTING.md`: no mention of the sandbox rule or of browser-driven tests | Both are the two rules that have cost this project real data | Both added, pointing at this file |
| 25 | Every README: "`doctor` needs no Full Disk Access" | It runs without the grant, but it cannot succeed: `~/Library/Mail` comes back `EPERM`, `doctor` prints the diagnosis and exits `1` (`cli.ts:259`) | Rewritten to state both halves |
| 26 | Every README: the version line cited `src/cli.ts:3` | That is the `package.json` import; `const VERSION = pkg.version` is `cli.ts:14` | Citation moved to the line that carries the value |

### Claims deliberately not made

- No benchmark. The only measured numbers in the docs are a dated `du`/scan snapshot on one machine,
  and they say so.
- No claim that the `freed` byte count equals the bytes of the deleted items. It does not, and the
  suite proves it (see above).
- No claim about `src/system/`. It implements startup-item and toolchain inspection but nothing
  imports it: no command, tool or route reaches it.

### Open questions for the next contributor

- `src/mcp/server.ts:10` hardcodes `serverInfo.version` to `"0.1.0"` while the CLI reports `0.1.2`
  from `package.json`. One line, but it needs a product decision, so it is documented as a wart in
  `docs/MCP.md` rather than silently fixed here.
- `src/core/verify/node.ts` exports `npmOrPnpmLinked`, `installAgeDays` and `isLiveDependencyTree`,
  and `verify/index.ts` calls none of them. The intent was evidently to spare a `node_modules` with
  live symlinks; today only `git_clean` guards that rule.
- `--version` prints usage rather than the version, and CI depends on that quirk
  (`.github/workflows/ci.yml:25`). Worth making explicit one way or the other.