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

### Honesty

- A scan reports what it could not look at: `ScanReport.unscannable` and `unscannableSummary` name
  every rule with no scannable path and a reason code, and those rules are excluded from every total
  (`src/core/scan.ts`, `scan`). The macOS app models both fields and ships the localized reason
  wording (`UnscannableRule`, `UnscannableSummary`, `UnscannableText` in
  `apps/dustless-mac/Sources/DustlessKit/Model/Reports.swift`).

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
