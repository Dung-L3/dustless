# Changelog

## Unreleased — 0.5.0

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

### Honesty

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

### Coverage

- End-to-end coverage for `awdl --on/--off` over a fake `sudo` and `ifconfig` inside the sandbox
  (`tests/e2e/awdl.test.ts`) and for the MCP server over stdio (`tests/e2e/mcp.test.ts`).

### Tooling

- `bun run typecheck` is green on the merged tree (unused imports, the generic `pick`).

Measured on this branch: `bun test` → 322 pass / 0 fail / 5 skip across 23 files; `bun test tests/e2e` → 111 pass / 0 fail / 5 skip across 9 files; log .autopilot/logs/gate-pr72-g5.log.
