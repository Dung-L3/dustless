# Changelog

## Unreleased

**Uninstall is now explicit about what it removes.** The confirmation has two named modes: remove the application only, or remove the application and a reviewed selection of related data. Every related path is checked individually; unchecked paths are never sent to the engine. A bundle-only result is titled "Application removed", not "Uninstalled", and says that related data remains. Related bytes shown in the result are only the paths that moved.

**A partial uninstall can be completed safely.** If the bundle moved but some related items failed, the result keeps the exact remaining paths and offers "Retry remaining data". The engine's related-only command revalidates the safe bundle id, allowed app path, target absence and template membership, then reuses the same double `realGuard` and Trash/purge path as the normal uninstall; already-moved items are skipped, and a reinstalled/moved app is refused with `target_changed`. Moving an app while the sheet is open is refused before the engine runs.

**Memory actions are honest and item-local.** Protected rows no longer offer Stop/Force Stop. A refusal from the engine is rendered as a per-item error, a process that already exited is reconciled instead of shown as a success, and a Quit is only marked successful after the process actually disappears. Force Stop and a refusing app are now covered by real compiled fixtures. Refresh requests made while a memory/apps read is in flight are coalesced instead of dropped.

**A scan explains a macOS permission wait when one occurs.** Five seconds into a scan, the app shows a "Waiting for access" card that says macOS *may* be asking and tells the user to choose Allow if the prompt is visible. A report with denied reads shows "Some folders could not be read" with Rescan, Open Files & Folders Settings and Dismiss; it never claims permission or a complete scan. This was verified against real Desktop/Downloads TCC prompts.

**Applications inventory was measured before changing it.** 32 apps / 70 related items still take about 4.3-5.2 s; the cost is the recursive app-bundle walk, not JSON. The related sizing now avoids a duplicate stat and runs concurrently, but the worker count stays at four and the UI keeps its loading state.


**A full interface redesign.** Dustless now uses a graphite design system with a single muted green accent, a grouped Workspace/System sidebar, larger page titles, tonal surfaces, progressive disclosure, and native SwiftUI motion with Reduce Motion support. The Overview is a focused dashboard (one reclaimable number, three measurements, one attention card, the three largest findings and four module shortcuts), and it shows a scanning state instead of repeating that nothing has been scanned while the first scan is running; Cleanup owns its tier pills; Storage is volumes and large files; Applications is its own module.

**Application management is a first-class feature.** The engine reports related data by kind, category and bounded size, and marks Apple/system apps protected. Applications lists every app with icon, size, related data, running state and a direct Uninstall. One confirmation shows affected locations and defaults to keeping related data, because Application Support and Containers can contain the user's own files. The running instances of that exact bundle path are asked to quit, never force-killed; if they stay open the uninstall is refused, and a same-bundle-id copy at another path is left alone. Helpers that share the bundle id but not the path no longer cause a false refusal. The default is Trash; permanent delete is a second explicit choice.

**Memory actions are direct.** Each app group has a graceful Quit action on the row that targets only that group's bundle path; per-process Stop and a visible Force Stop menu live in the expansion. Per-item state replaces the global lock, so one action never freezes the list.

**A scan can no longer hang on cloud-backed user folders.** Glob expansion used to read every directory under HOME before the red check, so `~/*/*/node_modules` opened `~/Desktop` and could wait indefinitely on an iCloud-managed folder. A red path is now dropped before it is traversed, and `CloudStorage` is red. Ordinary project `node_modules` still resolve; the real-home scan completes in 2.96 s.

**Contrast is part of the design system.** The popover primary action uses the same dark-on-accent treatment as the rest of the app instead of the system white-on-accent fill, and the muted metadata token was raised to meet WCAG AA on both raised and window surfaces. A test resolves the live dynamic tokens under Aqua and Dark Aqua and fails below 4.5:1.

**The window still reopens without a document alert.** Dustless no longer asks AppKit for a document it does not have. Closing the main window and opening it later from the menu bar used to produce "No document could be created."; the window is now reopened through its SwiftUI scene, the popover keeps working after a module row navigated, and the main content is laid out inside the window instead of a split view that grew to the height of the current module. The Storage wording no longer promises a password for every advanced action, the memory panel keeps its last reading with an error banner instead of blanking, and a running engine's "not found" stderr is no longer mistaken for a missing engine. The Accessibility suite now detects system dialogs, waits for a released window, and covers the window/popover/language/search/cancel journeys.

## 0.6.0

The delete path re-checks the rule that produced a finding, the app renders the engine's reasons in the
language the user chose, and the macOS release path is built and checked instead of being assembled by hand.

**The delete path had three holes that the audit did not find.** The scope of a rule was checked when the
rule was written and when the scan ran, but **not when the delete happened**, so a rule that was already in
`rules.yaml` and reached the direct children of `$HOME` was still deleted, and a finding whose rule id was
not in the rule set was deleted as well, with every rule-derived check skipped. The macOS red list covered
four Apple identifiers and was case sensitive, so `~/.Trash`, `~/Library/Mobile Documents`,
`~/Library/Containers/com.apple.*` and the Time Machine snapshots were deletable, and a differently cased
path slipped past it. And the Gradle verification was served from a thirty second cache, so inside one
process the delete trusted the verdict the scan had produced.

**The sudoers validator was a deny-list.** It refused a set of characters and allowed everything else, so a tab
in a network service name reached the rule, where sudo reads a tab as an argument separator; the rule was
also validated by deleting the quoted regions before testing the rest, so a forbidden character inside a
quoted region passed. The validator has a positive character set and checks the whole rule line now, and the
Network rule's executable is allowlisted like the AirDrop one was.

**$HOME could be spelled around.** macOS keeps the case a path was given, so `/users/mac` was neither
`$HOME` nor an ancestor of it. The comparison folds case on the platforms whose volumes are case insensitive,
and a relative `XDG_CONFIG_HOME` is ignored, so the rules file can no longer follow the working directory.

**The app renders the engine's data in the user's language.** The engine sends a reason code with its
parameters and the app renders it, so a Vietnamese or English sentence from the engine no longer appears
inside an English or Chinese interface, and a sentence no longer mixes two languages.

**Every permanent delete looks like one.** The button is a fixed red that does not follow the accent colour,
so it can never be the green the product uses for "safe"; Return does not delete; removing an application
moves it to the Trash and the permanent delete is a deliberate second choice; stopping a process and running
a network operation ask first and say what they will do.

**The macOS release path is real.** The bundle proves what it carries - the engine's hash, the architecture,
the version, the plist, and that the menu-bar mark is a real image and not a solid square. The disk image is
built, verified and mounted in CI on every pull request. The notarisation pipeline is implemented and refuses
to publish anything macOS would refuse to open.

**The screens can be looked at.** The real views render off screen into images, with no window server, no
Accessibility trust and no launched application, so the UI has a check that runs everywhere. It found two
defects no test had noticed: an engine error message that was cut off mid sentence, and a singular count
printed with a plural noun. Both are fixed in this release, with the rest of what the render pass and the
new regression net caught: every bundled rule now has a localized description (the engine's own `desc`
serves only a rule the user wrote), the engine error is shown once and never truncated, a rescan keeps the
user's selection and says what disappeared, the privileged network rule is re-checked by the app before it
is installed (the AirDrop rule already was), the schema version is checked before a report is decoded, the
engine's output is read from files instead of pipes so overlapping launches cannot hold each other's
descriptors open, and the storage panel's destructive buttons carry the same red as every other destructive
control. The render suite renders 18 screens in three languages; the wider QA merge adds 49 Swift tests over
the engine failure paths, the destructive paths (driven in a sandbox `HOME`) and the source-level contracts,
plus three TypeScript tests, so the boundary the pixels alone cannot see is checked too.

Versions 0.1.0 to 0.3.0 predate this file; their notes live in the GitHub releases. Versions 0.4.0 and
0.5.0 are described in the notes of their own releases.
## 0.5.0

The first release with the macOS app built by the release workflow, the required checks that actually
block a merge, and the delete path that re-checks a finding before it removes it.

Versions 0.1.0 to 0.3.0 predate this file; their notes live in the GitHub releases.


### Safety

- The red-list match normalises a path before testing it — duplicate separators collapse,
  backslashes become `/`, a trailing separator is dropped — so `~/Mail/` and a doubled-slash
  `Application Support/com.apple.*` path are red (`src/core/paths.ts`, `isRed`). Locked by the
  seeded property tests (`tests/property/redlist.test.ts`) and the symlink-escape end-to-end cases
  (`tests/e2e/symlink-red.test.ts`).
- Fuzz cases for the `--only-file` selection set and for bundle-id traversal (`tests/e2e/onlyfile-fuzz.test.ts`).
- A scan resolves a candidate's real path before the red-list test, so a cache directory that is
  really a symlink into a red directory (Documents, Keychains, `.git`, …) is never counted as
  reclaimable and is instead reported as unscannable with the new `red` reason
  (`src/core/scan.ts`, `candidates`; `src/core/paths.ts`, `isRedReal`). The app models and localizes
  the reason (`UnscannableReason.red`, key `scan.unscannable.reason.red`).
- A delete re-resolves the real path at the moment of removal and refuses if it changed: `moveToTrash`
  and the purge path in `src/core/apps/index.ts` take the same `realGuard` reading twice, once before
  the trash slot is chosen and again immediately before `rename`/`rm`, and `deleteLargeFile`
  (`src/core/largefiles/index.ts`) uses `realGuard` at its gate. A path that is swapped for a symlink
  into a red directory, or retargeted to a different real directory, between the check and the delete
  is refused with a localized reason and left untouched. Locked by `tests/race-delete.test.ts`, whose
  `beforeDelete` hook performs the swap.
- The apply path and the MCP delete guard re-resolve the real path at the moment of removal too:
  `remove` (`src/core/apply.ts`) reads `realGuard` before and immediately before the `rm` and refuses
  when the target changed or resolves into a red directory, and `assertPathDeletable`
  (`src/mcp/safety.ts`) uses `realGuard` for its red test. Locked by `tests/race-delete-apply.test.ts`,
  whose `beforeDelete` hook performs the swap.
- `realGuard` now also refuses the resolved HOME, every ancestor of HOME and the filesystem root
  (`protected`) and any path reached through a symlinked directory (`symlinked`); a leaf symlink stays
  removable without following it. The MCP guard reports each refusal separately. This closes the
  symlinked-parent case where a cache-shaped finding was deleted at its real target.
- `isSafeBundleId` refuses the bundle id `"."` and control characters. `"."` collapsed every leftover
  template onto its parent, so `apps --uninstall --purge` could delete `~/Library/Caches` or
  `~/Library/Preferences`; a `Library/Caches` canary now locks it (`tests/apps.test.ts`).
- `apply` keeps a finding's own `yellow` tier even when the per-rule choice says `green`, and the CLI
  and MCP tier maps choose the strictest tier for a rule that yields both tiers.
- A declared `busyProcesses` list now gates the delete; previously only `nativeCommand` was consulted.
  Names are basenamed and lowercased before matching, and a Windows retry re-reads the guard before
  each attempt.
- A leaf symlink is deleted as a link even when the finding carries a trailing separator or comes
  from a wildcard rule: glob results are resolved, and every deleter normalizes with `resolve`
  before both the guard and the syscall, so `rm` is never handed `<link>/` and cannot recurse into
  the target. A rule id inherited from `Object.prototype` no longer selects a finding when the tier
  map has no own entry (`Object.hasOwn`).
- The Windows Chrome and Edge rules no longer target the whole `User Data` profile directory as a
  green cache; they target only the regenerable cache leaves (`ShaderCache`, `GrShaderCache`,
  `GraphiteDawnCache`, per-profile `Cache`, `Code Cache`, `GPUCache`, `Service Worker/CacheStorage`),
  so a green delete cannot remove passwords, cookies, bookmarks or history.
- The scan `roots` filter matches on a path boundary, not a string prefix: `/home/u/cache-evil` is not
  inside a root of `/home/u/cache`, and the root itself and `/` stay included (`src/core/scan.ts`,
  `withinRoots`).
- The MCP `scan` summary counts a blocked finding in the `blocked` bucket and excludes it from
  `reclaimable`, matching the engine report instead of presenting it as reclaimable green/yellow
  bytes (`src/mcp/tools.ts`, `tally`).

### Honesty

- A scan measures a symlinked root as the link itself, and `dirSize` does the same, matching what
  the delete actually removes instead of the target's bytes.
- A scan reports what it could not look at: `ScanReport.unscannable` and `unscannableSummary` name
  every rule with no scannable path and a reason code, and those rules are excluded from every total
  (`src/core/scan.ts`, `scan`). The macOS app models both fields and ships the localized reason
  wording (`UnscannableRule`, `UnscannableSummary`, `UnscannableText` in
  `apps/dustless-mac/Sources/DustlessKit/Model/Reports.swift`).
- A finding whose path disappeared before `apply` reached it is reported `skipped` instead of
  `deleted`, because `rm` with `force` succeeds silently on a missing path.

### Rules

- The rule schema gained `recoveryLabel`, `busyProcesses`, `staleDays`, `gitClean` and
  `nativeCommand`, each validated on load; `nativeCommand` is refused when its first token contains a
  path separator or its value contains shell metacharacters (`src/core/rules.ts`, `defect`). Every
  bundled rule carries a `recoveryLabel`.
- `match` must be a string that compiles as a regular expression, `requireVerify` must name one of
  the implemented verifiers, `minAgeDays` must be a non-negative integer, `tier` must be a string,
  and a rule id is restricted to `[A-Za-z0-9][A-Za-z0-9._-]*`; `rule add` runs this validation before
  appending and quotes the id in the generated YAML, so invalid input leaves the file untouched and
  a reserved-looking id such as `123` or `true` still loads as a string (`src/core/rules.ts`,
  `src/cli/rule.ts`).
- Two Windows paths used the nonexistent `%USERPRO%` variable; they now use `%USERPROFILE%`.

### Coverage

- End-to-end coverage for `awdl --on/--off` over a fake `sudo` and `ifconfig` inside the sandbox
  (`tests/e2e/awdl.test.ts`) and for the MCP server over stdio (`tests/e2e/mcp.test.ts`).

### Tooling

- `bun run typecheck` is green on the merged tree (unused imports, the generic `pick`).

Measured on this branch: `bun test` → 451 pass / 0 fail / 20 skip across 33 files; `bun run typecheck` clean;
`cd apps/dustless-mac && swift test` → 81 tests in 12 suites.

### What this release fixes

- The sudoers rule that lets the app toggle AirDrop no longer takes its executable from the environment.
  The rule is built by one allowlisted validator, the app re-checks the payload before it installs anything
  as root, and the environment variable is gone from the shipped binary.
- The app can no longer resolve the engine to its own executable. On a case insensitive volume
  `Contents/MacOS/dustless` is the app itself, so a bundle whose engine was missing turned the app into a
  fork bomb. The candidate list can no longer contain the app, every candidate is compared by real file
  identity, and the bundle build fails when the copied engine does not answer.
- A rule can no longer widen the delete scope to the direct children of `$HOME`, and a glob with more than
  one `*` now matches what it says. The filesystem root, `$HOME` and its ancestors are reported as
  unscannable instead of being counted as reclaimable.
- A finding is re-checked before it is deleted: the age floor, the verification and the repository state are
  measured again, and an unverifiable tree is skipped rather than removed.
- The bytes that were deleted and the free space the volume gained are two different numbers and are now
  reported as two different numbers.
- The app says which rules it could not scan, and says so in the language the user chose. The engine sends
  a reason code and the app renders it, so no Vietnamese or English sentence from the engine appears
  inside an English or Chinese interface.
- Every permanent delete is a fixed red button that does not follow the accent colour, so it can never be
  the green the product uses for "safe". Return no longer deletes.
- The engine payload carries a schema version and the app refuses a major version it does not understand.
- The macOS and Windows jobs, the Swift job and a macOS build job are required checks, and the release
  workflow runs every binary it publishes, ships `SHA256SUMS`, and builds the app bundle and the disk image
  instead of leaving them to a manual upload.
