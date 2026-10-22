# Testing

```sh
bun run typecheck     # tsc --noEmit over src, tests and scripts
bun test              # 474 tests, about 40s; 20 skips unless DUSTLESS_UI=1
bun run lint          # repository policy checks
cd apps/dustless-mac && swift test   # 148 Swift tests, about 100s
bun run test:ui       # real macOS app UI suite; needs Accessibility trust; see below
```

No build step is needed for the engine suite. `tests/e2e` runs the compiled
binary in `dist/`, and the e2e harness builds it before the first assertion, so
you do not have to remember `bun run build` first.

## The macOS app has three test suites

| Suite | Command | Needs a GUI session | Blocks a merge |
| --- | --- | --- | --- |
| Engine, TypeScript | `bun test` | no | yes, `verify` |
| App render + unit, Swift | `cd apps/dustless-mac && swift test` | no | yes, `ui-render (macos)` |
| App interaction, Accessibility | `bun run test:ui` | yes, Accessibility trust | no, `ui (macos, advisory)` |

They are three different questions and none of them answers all three.

### The render suite: `apps/dustless-mac/Tests`

The render suite builds the real SwiftUI views with the real fixture data and
draws them off screen with `ImageRenderer`. It needs no window server, no
Accessibility trust and no launched application, so it runs on any macOS
machine and in CI. The images land in `artifacts/ui-render/` (ignored by git).

The catalogue in `Screens.swift` holds 18 screens: the overview, the cleanup
screen and its finding list, the confirm sheet, the storage screen and its
application and file list, the memory panel, the network panel, the menu bar
popover, the settings window, the unscannable notice, the engine error state
and its message, the uninstall sheet, the trash sheet, the cleanup result card,
the tier badges and the destructive controls. Every screen is drawn in
Vietnamese, English and Chinese, so 54 images.

What the render suite proves:

- every screen builds and draws; a screen that renders empty fails.
- the destructive control is painted with the app's own red
  (`DestructiveStyle.red`), it is a wide control in the footer on the right,
  and the cancel control next to it is neither red nor the same colour.
- the SAFE tier badge is painted green, YOUR CALL is orange, PROTECTED is red,
  and the blocked reason is red, wherever those appear.
- the three languages draw the same rows in the same places: same number of
  text bands, same vertical centres, same leading edge, and the delete button
  does not move. A translation that wraps into an extra row or pushes the
  layout sideways fails.
- a reason on screen is a translated sentence, not a bare code: the rendered
  pixels change when only the reason's parameters change, and the drawn reason
  is as wide as the translated sentence and several times wider than the raw
  code would be.
- the engine failure paths produce the right error: a missing engine names
  every path it searched and starts nothing, a non-zero exit names its status,
  an unreadable payload says so, a hanging engine reports the deadline, a
  report with no findings and a report where everything is locked offer no
  delete control at all.
- the destructive paths behave inside a sandbox: cancelling runs nothing,
  confirming deletes exactly the selected paths, a locked path is never
  deleted, a path that vanished is reported and not deleted, a red listed path
  is refused, a path outside the sandbox is refused, the default uninstall
  moves the app to the Trash and the permanent delete has to be asked for.
- the source contracts hold: the confirm sheet has no default action and no
  Return shortcut, the shortcut that reaches the delete review is ⌘↩, no
  `accessibilityElement(children: .combine)` wraps a button, and no view reads
  a reason's `code`.

What the render suite cannot prove, and why:

- `ImageRenderer` does not draw the content of a `ScrollView`, a `List`, a
  `LazyVStack`, a `Picker` or a text field. The confirm sheet therefore draws
  its header, its totals and its buttons but not the list of paths, and the
  cleanup and storage screens draw their chrome but not their scrolled rows.
  The rows themselves are covered by the separate list screens
  (`cleanup-list`, `storage-list`), which are drawn without a scroll container.
- It cannot prove that a click does what it says. Nothing is clicked; the
  views are drawn and their pixels are measured.
- It cannot see the accessibility tree, the focus order, the keyboard
  behaviour, the window chrome or the real appearance of the app in a window.
- It runs against fixtures, not against the real engine, so it proves nothing
  about what the engine does. The engine's own behaviour is covered by the
  TypeScript suite and by the Accessibility suite.

### A note on concurrent engine launches

`DustlessCLI.ProcessLauncher` reads the engine's output through a pipe. A child
process inherits every descriptor the parent has open, so two engine launches
that overlap can leave one of them waiting for the *other* child to exit before
it sees the end of its own pipe. The engine's own timeout then fires and the
launch is reported as timed out even though the engine answered. The render
suite's launcher writes to a file instead of a pipe, and the suites that spawn
engines are marked `.serialized`, so the suites do not trip over each other.
The production launcher is not changed by this branch. The fix belongs there:
close the inherited descriptors in the child (`POSIX_SPAWN_CLOEXEC_DEFAULT`) or
read the engine's output from a file.

### The Accessibility suite: `tests/ui`

`bun run test:ui` drives the real SwiftUI app through the Accessibility API.
It builds both the engine and a test-only app bundle (`dev.dustless.e2e`,
process `DustlessE2E`), presses the controls a user would press, and asserts on
the filesystem afterwards.

Requirements: macOS, Xcode or the Command Line Tools (`swiftc`), and
Accessibility trust for the terminal or process that starts the tests. Without
that trust the driver cannot inspect another app's window; `DUSTLESS_UI=1` then
fails with an explicit message instead of reporting a skipped suite. Plain
`bun test` skips the UI cases because it does not set `DUSTLESS_UI=1`; that
is the only skip condition for this file. Setting `DUSTLESS_UI=1` on a
non-macOS host fails rather than skipping.

XCUITest is not used: enabling UI automation makes `xcodebuild test` ask for
administrator credentials or developer mode on this host, so it cannot run
unattended. `tests/ui/AXDriver.swift` is a small compiled `AXUIElement` and
`CGEvent` driver. The app is launched by its executable rather than through
`open`, so the harness controls its environment.

The suite covers launch and overview, sidebar and Go menu navigation, the
menu-bar popover, settings persistence, Vietnamese language loading,
network/AWDL actions through an intercepted engine, app uninstall and Move to
Trash, cleanup cancel/delete with a real failed deletion, and stopping one
sandboxed process while a sibling fixture process stays alive. Synthetic
keyboard shortcuts are not asserted: posted key
events were not reliably delivered as menu key equivalents in this harness, so
the same routes are exercised through the Go menu instead of pretending the
shortcut ran.

`tests/ui/identifiers.test.ts` guards the identifiers the suite drives: every
identifier the suite uses must exist in the app, and the identifiers that no
test uses are printed, so they are reported rather than deleted silently.

#### Sandbox guarantees

Each case gets an `mkdtemp` root and launches the app with `HOME`,
`CFFIXED_USER_HOME` and `TMPDIR` inside it. Preferences go to
`DUSTLESS_PREFS_FILE`, not `UserDefaults` (`CFFIXED_USER_HOME` does not redirect
`UserDefaults`), and privilege files are read from `DUSTLESS_SUDOERS_DIR`, never
`/etc/sudoers.d`. The engine receives `DUSTLESS_APPS_DIRS` pointing only at the
sandbox's `~/Applications`, so the Storage panel never lists or offers to
uninstall a real app; without that seam the first run listed 23 real
`/Applications` entries. The rules file also overrides every bundled rule id
with a sandbox-only no-op path, so absolute defaults such as
`/opt/homebrew/var/homebrew/cache` cannot become selectable findings. The
cleanup case proves exactly two fixture findings are selected before it acts.
Destructive cases assert the fixture's filesystem result: a bundle and its cache
are gone, a sparse file is under the sandbox `.Trash`, one cleanup fixture is
deleted and an immutable fixture is reported failed while an outside canary
survives.

The network case replaces the bundled engine with a wrapper
(`DUSTLESS_E2E_INTERCEPT`) that answers only `net` and `awdl` commands from
fixtures and delegates every other command to the real engine. It asserts the
exact intercepted invocations and the fake AWDL state file. The tested net and
AWDL actions never reach the privilege-install path (which uses `osascript`);
that path is not exercised by the suite. No real route, DNS, AirDrop or
privilege setting is touched.

AppKit still autosaves window frames and the status-item position in
`~/Library/Preferences/dev.dustless.e2e.plist`, outside the sandbox. That is a
test-only bundle domain containing no production settings; the harness removes
it before and after a run. The engine's cleanup selection file is redirected to
`DUSTLESS_SELECTION_DIR` inside the sandbox, and the app's own settings use
`DUSTLESS_PREFS_FILE`.

Artifacts (screenshots and AX dumps on failure) go to `artifacts/ui/`, which is
ignored. The test app is built at `artifacts/ui/build/` and copied to
`artifacts/ui/app/`; the production `dist/Dustless.app` is not overwritten. The
AX driver is built in `.ui-bin/`. Screenshots are window-only; if the window id
is missing, the screenshot fails rather than capturing the desktop.

### What only a trusted host can prove

These are facts about this project, not gaps to paper over:

- That a click does what it says. The render suite draws the button and
  measures its pixels; it never presses it. Only the Accessibility suite
  presses `confirm.delete` and then checks the filesystem.
- That the app's own accessibility tree is what the user hears: the roles,
  the labels, the values and the traits of the real elements in a real window.
- That the keyboard shortcuts work: ⌘↩ reaches the review, Return does not
  delete, Escape cancels. The render suite asserts the shortcut configuration
  in the source, because the Accessibility suite cannot deliver synthetic key
  events reliably.
- That the menu bar popover opens, that the status item is drawn by the system
  and that the settings window opens as a window.
- That the app looks right in a real window, at the real window size, with the
  real appearance and the real focus ring.

So the honest statement is: **the click did what it says is proven only by the
Accessibility suite on a trusted host.** A local `bun run test:ui` on an
AX-trusted machine is the evidence for that, and CI cannot produce it. Do not
turn its failure into a skip, and do not pretend the render suite covers it.

### The CI jobs

- `verify` runs the TypeScript suite on Linux, macOS and Windows.
- `swift (macos)` runs `swift test` in the app package.
- `ui-render (macos)` is the gate for the macOS app. It runs the whole Swift
  suite, including the render suite, and uploads `artifacts/ui-render/` so a
  reviewer can look at every screen in every language. It has no
  `continue-on-error`, so it blocks a merge. Add it to the branch protection's
  required checks.
- `ui (macos, advisory)` still runs `bun run test:ui` with
  `continue-on-error: true`, because GitHub-hosted macOS runners do not
  guarantee an AX-trusted GUI session. It is not a merge gate and it must not
  become one by being made to pass.

## Browser-driven testing is deliberately not automated

Do not add a suite that launches a browser.

No browser binaries, no Playwright/Puppeteer/Selenium/WebDriver, no `open`, no `webbrowser`, no
`osascript`, no browser profile flags, and no touching `security` or the login keychain. A Chromium
browser started with a fresh profile makes macOS prompt for a `… Safe Storage` keychain item, and
that prompt is about **your real login keychain**. It is not a test problem you can configure around;
it is the browser asking for a credential that belongs to the person sitting at the machine.

## The sandbox rule

**Anything that can delete must run in a child process whose environment carries `HOME` pointing at
a throwaway directory.** `tests/e2e/harness.ts` `mkdtemp`s a root, `mkdir home`, plants files,
spawns the compiled binary with `HOME` and `XDG_CONFIG_HOME` in the child's env, and `rm -rf`s the
root afterwards. It additionally refuses a `HOME` that is not under the OS temp directory.

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
sandbox.

## What is expected to fail right now

Nothing, in `tests/e2e/`.

`freed` is `max(0, freeAfter - freeBefore)` — the change in free space on the **whole volume**
(`src/core/apply.ts:35`), not a sum of the deleted items. Two checks assert on it:
`tests/core.test.ts` "reports freed as the measured disk delta between freeBefore and freeAfter" and
`tests/e2e/outputs.test.ts` "apply --json reports outcomes and freed bytes". Both compare `freed`
against the same delta they measure around the call, so they only fail if another process fills or
frees the disk between the two reads. An earlier version asserted `freed > 0` and did flake under the
rest of the suite planting and deleting hundreds of megabytes in parallel; that is why the check is
now self-measured. If you touch `freed`, keep asserting on the per-outcome `status` as well, or take
the delta against a filesystem the test owns.

Two Swift tests fail on purpose, because they describe a promise the app does not
keep yet. They are the reason the `ui-render (macos)` gate is red, and they
must stay red until the app is fixed.

| Test | What it says |
| --- | --- |
| `ScreenReasonTests.theReasonTableCoversEveryCodeTheEngineCanSend` | `not_determinable`, `not_executable` and `engine_unavailable` are reason codes the engine can send and the app has no translation for, so the screen shows the raw `reason.<code>`. |
| `EngineFailureTests.anUnsupportedSchemaVersionIsReported` | A report whose `schemaVersion` the app does not understand is accepted and shown, instead of being refused with a message that names both versions. |

Both need a change in `apps/dustless-mac/Sources/DustlessKit`, not in the
tests. Do not weaken the tests to make them green.

## Documentation audit

Run on branch `docs/accuracy`, 2026-10-11, against `main` at `cf2f23f`. Every claim below was checked
against the source at the cited line; markdown only was touched.

This is a dated snapshot of that audit, kept as a record. Rows mentioning `src/ui`, `server.ts` or
`tests/e2e-ui` describe a local web UI that existed then and has since been removed — this project is
a native app now.

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
- No claim that `src/system/` is dead code. `doctor` calls `inspectSystem()` and reports startup
  items and toolchain roots, both in the human output and under the `hygiene` key of `doctor --json`.

### Resolved since the audit

- `src/mcp/server.ts:12` now reports `package.json`'s version through `SERVER_INFO`, so
  `serverInfo.version` tracks `dustless version`. The wart paragraph is gone from `docs/MCP.md`.
- `src/core/verify/node.ts`'s `isLiveDependencyTree` is wired into `verify/index.ts:11` for every
  `node_modules` finding. `npmOrPnpmLinked` is still only used by tests; that one is a candidate for
  deletion rather than wiring.
- `--version` prints the version, and CI checks it (`.github/workflows/ci.yml:40`). `--help` now
  prints usage wherever it appears, so the old "the command wins after the command word" quirk is
  gone and the READMEs say so.