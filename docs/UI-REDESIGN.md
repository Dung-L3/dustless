# UI redesign — Quick Control Center (2026-10)

Scope, evidence and the behavior decisions for the macOS UI redesign pass.
Sources: read-only audits of every view, the store/flow trace UI→engine, the
accessibility/localization audit, and the UI test harness audit. The permanent
"why this can not work differently" entries live in `docs/DECISIONS.md`; this
file records the design and the audit that produced it.

## Audit findings

| # | Finding | Evidence | Fix |
| --- | --- | --- | --- |
| A1 | The popover shows four flat metrics and a module list but hides what the user can *do*: nothing connects "reclaimable X" to an action when nothing is selected, and there is no path to a one-tap safe cleanup. | `MenuBarContent.actions`: three branches (scan/pick/review) only. | Primary action becomes a state machine including a scoped quick clean (below). |
| A2 | Deletion requires ticking items in the Cleanup tab first — three interactions before the confirmation (switch module → select all → review). The engine already validates and revalidates everything at apply time. | `ScanStore.clean` → `apply --only-file`; `docs/DECISIONS.md` 57, 126. | Quick clean pre-scopes the *existing* confirmation sheet to green-tier findings; the sheet still lists every path before anything happens. |
| A3 | Destructive confirmations are inconsistent: `UninstallConfirmationSheet` and `LargeFileTrashSheet` use plain bordered buttons, only `ConfirmDeleteSheet` uses `DestructiveButton`. | `StorageSheets.swift`. | Route every destructive confirmation through `DestructiveButton`. |
| A4 | Force stop (SIGKILL) shares its dialog wording with the ordinary stop (SIGTERM); the reader cannot tell that one cannot be intercepted. | `MemoryView` `PendingStop` dialog. | Force stop gets its own title/body that name SIGKILL and the lost-save consequence. |
| A5 | A finished cleanup leaves no residue in the popover: `lastApply` (real `deletedBytes` vs `freed`) is shown only in Dashboard/Cleanup result cards. | `ScanStore.lastApply` flûrished only via `CleanupResultCard`/Overview. | Popover shows the measured pair (deleted bytes / volume delta) with distinct labels — never one number. |
| A6 | Memory panel has no bounded "what eats RAM" answer at a glance; the top bundle is real data the engine already returns (`memoryReport.processes`). | `Memory.swift` model. | The popover memory row states pressure + top consumer, and links to the module for the bounded, real action (stop = SIGTERM; force stop = SIGKILL behind a distinct dialog). No "free RAM" action anywhere: macOS has no honest one; `purge` stays out of the product. |
| A7 | Icon-only buttons rely on `.help` only in a few places; the popover rows already carry `accessibilityLabel`+`accessibilityIdentifier`. | grep audit. | New icon-only controls ship with both from the start. |

## The popover (fixed 340pt Quick Control Center)

Layout, top to bottom — everything binds to real `ScanStore`/`NetControl`/`AwdlControl` state:

1. **Header**: Dustless mark + name, right-aligned window-open and settings controls.
   `provenance` line (last scan age), engine-failure line, compact unscannable notice — unchanged semantics.
2. **Status card** (`menubar.status`): 2×2 `PanelStat` grid — Free space, Reclaimable, Memory pressure, Network.
   Memory stat shows pressure + the top consumer's measured RSS when the read has one; `—` when it doesn't.
3. **Primary action** — one prominent button driven by a single state machine:
   - resolving/scanning → inline progress + the busy message, disabled;
   - no report → **Scan now** (`menubar.scan`);
   - report + nonzero selection → **Review & Delete (n · size)** (`menubar.review`) — existing sheet;
   - report + green deletables and no selection → **Clean safely (n · size)** (`menubar.quickClean`) — pre-scopes the confirmation sheet to green-tier deletable findings;
   - report else → **Choose items to clean…** (`menubar.pick`).
   A finished run renders the result line (`menubar.count`, real `deletedBytes`/`freed`) under the action, `—` never rendered as `0 B`.
4. **Quick actions**: Memory (opens Memory module) sits with the module rows; Rescan stays a button.
5. **Module rows** (`menubar.module.*`): unchanged identifiers, tightened row rhythm; cleanup row carries the live selected/locked counts.
6. **AirDrop row**: unchanged behavior; state is text + color, never color alone.
7. **Footer**: Open Dustless, Settings, Quit (`menubar.open`, `menubar.settings`, `menubar.quit`).

Quick clean is *not* a second delete mechanism: it selects green-tier findings in `ScanStore` (`selectQuickClean`), opens the module, and shows the same `ConfirmDeleteSheet` the manual flow uses; the engine keeps `--only-file`, refusal, re-validate and real-path guards. Cancel leaves the selection in the Cleanup tab where the user can deselect. The measured last-apply line (`menubar.result`) pairs `deletedBytes` with the volume delta; `freed` alone never masquerades as "removed data".

## The window (same design system)

- Overview gains the same clean-safely CTA when green deletables exist (same store flow, no new branch of behavior).
- `PanelStat` values get a hard `truncationMode(.tail)` on long values (DNS list) — the modifier on the *wrapper* was inert; the inner Text owns it.
- Destructive-button consistency (A3) and force-stop wording (A4).
- Hardcoded spacings in the touched files move to `PanelStyle.Space` tokens; fonts stay on `PanelFont` (fixed sizes are the recorded tradeoff for this data-dense utility, see DECISIONS entry).

## Honesty constraints carried over

No scan pre-selection (DECISIONS 71) — quick clean is an explicit user gesture that pre-scopes a visible confirmation, nothing deletes without the sheet. Values the pipeline did not measure render `—` (DECISIONS 25) and `deletedBytes` vs volume delta never merge (DECISIONS 128). No new teardown paths; the app never kills anything a user has not confirmed. The popover memory line reports the top process group with `groupedByApp()` (DECISIONS 38): bundle totals, not a single biggest process.

## Test plan

- Existing identifiers are contract: every `menubar.*` identifier referenced by `tests/ui/app.test.ts` keeps its meaning.
- New: `menubar.status`, `menubar.quickClean`, `menubar.result`, `menubar.busy`, `menubar.top-memory`.
- Swift unit tests: quick-clean scope helper (green-only, deletable-only, empty cases).
- UI suite additions: popover opens with the status card; quick clean shows the sheet with exactly the green fixtures; cancel deletes nothing; confirm deletes through the engine log; popover survives and shows the measured result.
- Localization: new keys land in all three dictionaries; `tests/i18n.test.ts` guards the rest.
