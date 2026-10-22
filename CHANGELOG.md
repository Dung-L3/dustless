# Changelog

## Unreleased

Nothing yet.

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
printed with a plural noun.

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
