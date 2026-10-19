# Threat model

What Dustless assumes about the machine it runs on, what an attacker would want from it, and
what the code does about each. Every mitigation names the file and the symbol that implements it. A
claim that could not be checked against the source is marked **unverified**; every number here was
read out of the code.

## Assets

- **The user's documents and media** — the files Dustless is most useful against and the ones it
  must never touch.
- **The installed applications** — the `.app` bundles, and the leftovers a `--purge` removes.
- **The record of what was deleted.** Dustless keeps none: no persisted operation history, no log of
  past runs. The only file it writes outside a temp directory is the user rule file (`configDir`
  and `userRulesPath` in `src/core/rules.ts`, appended by `rule add` in `src/cli/rule.ts`).
- **The machine's network posture** — DNS resolvers, the default route, the AirDrop/AWDL interface,
  and the sudo rules that let Dustless change them.

## Non-goal: no telemetry, no accounts

There is no telemetry, no account, no upsell, and no code path that sends data anywhere
(invariant 3). That is a statement about what this product does; it is not a claim about the
network stack, the browser, or any other software on the machine.

## 1. A malicious app bundle id

- **Asset:** documents and media outside `$HOME`, and any path derived from a crafted identifier.
- **Attack:** an app whose `CFBundleIdentifier` contains `/`, `\` or `..` is uninstalled, and the
  leftover templates (`join(home, "{id}/…")`) collapse to a path outside `$HOME`; `--purge` then
  removes it permanently. The id `"."` is the same attack one level down: every template keeps its
  parent (`~/Library/Caches`, `~/Library/Preferences`, …) instead of a child.
- **Mitigation:** `isSafeBundleId` (`src/core/apps/index.ts`) rejects an empty id, the id `"."`,
  any id containing `/`, `\` or `..`, and any control character (U+0000–U+001F, U+007F).
  `deriveRelatedPaths` returns nothing for an unsafe id, and `uninstall` refuses the whole
  operation rather than removing the bundle and leaving unknown leftovers. Every derived path is
  re-checked with `isUnder(HOME)` and against the exact set of this id's own template expansions
  before it is touched (`uninstall` in `src/core/apps/index.ts`). The caller is never trusted for a
  derived path: `apps --uninstall` takes the `.app` path, and the id is read from its `Info.plist`.
  The delete paths then re-resolve the real target with `realGuard` (section 2), so a leftover that
  is itself a symlink into a protected directory is refused rather than followed.
- **Residual risk:** the id check and the path check are lexical (`resolve`, not `realpath`). A
  hostile bundle is not the trust boundary — the user chose to uninstall that app — so this guards a
  malformed plist and a mistake, not a local attacker who can already write into `$HOME`.

## 2. A symlink swapped in between scan and delete (TOCTOU)

- **Asset:** whatever a red path or a refusal was meant to protect.
- **Attack:** a path is a harmless cache directory when `scan` reads it and a link to `~/Documents`
  (or `~/Library/Mail`) when `apply` removes it.
- **Mitigation:** every delete resolves the real target at removal time with `realGuard`
  (`src/core/paths.ts`). It refuses a target that is red-listed (`red`), cannot be resolved
  (`unresolvable`), is the resolved `$HOME`, any ancestor of `$HOME` or the filesystem root
  (`protected`), or is reached through a symlinked directory component (`symlinked`). A leaf symlink
  is allowed: `rename`/`rm` act on the link itself, never on its target. Every deleter resolves the
  path once and passes that same string to the guard and the syscall; glob results are resolved before
  they become findings, so a trailing separator cannot hand `rm` a `<link>/` that recurses into the
  target. The guard is read twice — once before the target is sized or a trash slot is chosen, and
  again immediately before the `rename`/`rm` — and a second reading that differs from the first is
  refused (`changed`); the Windows retry loop re-reads it before every attempt. A missing path checks
  its parent's real path, so `link/missing` where `link` points into HOME or a red directory is
  refused rather than waved through as unresolved; a dangling parent symlink is refused too. It is
  called from `remove` (`src/core/apply.ts`), `moveToTrash`/`purgePath` (`src/core/apps/index.ts`),
  `deleteLargeFile` (`src/core/largefiles/index.ts`) and `assertPathDeletable`
  (`src/mcp/safety.ts`). `isRed` (`src/core/paths.ts`) normalises duplicate separators, backslashes
  and trailing separators before matching, and `isRedReal` applies that test to the resolved path
  during the scan, so links into a red directory are never reported as reclaimable. The lexical
  `refusal` gate in `apply` remains in front of the real-path gate as a second, independent check.
  macOS `/private/{var,tmp,etc}` aliases and Windows case are canonicalised before the real-path
  comparison so ordinary temp paths are not misread as links. The symlinked-parent data-loss case is
  locked by `tests/race-delete.test.ts` and `tests/race-delete-apply.test.ts`, and the e2e
  `tests/e2e/edges.test.ts` cases keep a symlinked cache root from being deleted through.
- **Residual risk:** the real-path check and the path-based `rename`/`rm` are not one atomic
  operation. A component swapped between the second `realpathSync` and the syscall can still be
  followed; the true close is `O_NOFOLLOW`/`unlinkat` by file descriptor, which `node:fs` does not
  expose. The busy-process gate is also fail-open when `ps` cannot be run (the set is empty), and a
  path spelled with different letter case on a case-insensitive filesystem can be refused as
  `symlinked`; both err in the direction of refusing a delete, not of performing one. On Windows a
  directory junction is treated as a removable leaf link; whether the Bun runtime's recursive `rm`
  follows a junction is **unverified** on that platform, so the guard refuses the junction path only
  when it is reached through a parent, not merely because it is a junction.

## 3. A tampered rule file

- **Asset:** whatever a widened rule could delete.
- **Attack:** a rule file that smuggles a shell command into `nativeCommand`, claims a tier it may
  not have, or tries to disable the red list.
- **Mitigation:** `loadRules` (`src/core/rules.ts`) rejects unknown fields (the `RULE_FIELDS` list),
  any tier outside `green`/`yellow`, and an empty description or path; `defect` rejects a
  `nativeCommand` whose first token contains a path separator or whose value contains any of
  `; | & $ > <` or a backtick. The red list is `RED_PATTERNS`, compiled into the binary
  (`src/core/paths.ts`); no rule field can name it, and a rule can only add paths for `scan` to
  inspect, never remove a red entry. The refusal guards are re-derived from the compiled list at
  delete time, not from the file.
- **Residual risk:** a user rule can still widen what is deletable on the user's own machine, by
  design. Coverage today is schema validation (`defect`, `tests/rules-schema.test.ts`); that a
  hostile rule file cannot influence a real delete is **unverified** end to end.

## 4. MCP prompt injection

- **Asset:** everything a `confirm: true` call can delete.
- **Attack:** an MCP client — or text the model read — convinces the agent to pass `confirm: true`,
  a red path, or an unknown id.
- **Mitigation:** the tool surface takes rule **ids**, never paths (`src/mcp/tools.ts`): `apply`
  accepts `rule_ids`, `tier`, `confirm` and `allow_large`, and no path argument exists.
  `assertAgentCanDelete` (`src/mcp/safety.ts`) refuses unless `confirm` is exactly `true`;
  `assertNoUnknownRules`, `assertTierPermitted`, `assertPathDeletable` (re-runs `isRed`),
  `assertNotBlocked` and `assertWithinAgentCap` (refuses over `MAX_AGENT_DELETE_BYTES` without
  `allow_large`) each collect every problem, and `applyTool` refuses the whole call when any guard
  trips — all-or-nothing.
- **Residual risk:** the gate bounds a successful injection to what the user's own `apply` could
  reach. `confirm` is a boolean the model controls, so the protection is the workflow (show the byte
  count, get a recorded yes), not cryptography; a model that ignores its instructions defeats it.
  **unverified:** nothing binds `confirm` to an out-of-band human approval.

## 5. A hostile or buggy engine payload

- **Asset:** the app's reading of a payload it did not produce.
- **Attack:** run the app against an engine that emits an unexpected shape, and let it decode into a
  wrong report.
- **Mitigation:** **not implemented yet.** There is no `schemaVersion` in the engine's JSON
  (`src/types.ts`) and nothing in the Swift decoder (`DustlessCLI.decode` in
  `apps/dustless-mac/Sources/DustlessKit/Engine/DustlessCLI.swift`) checks one; it decodes by shape
  alone. **What would close it:** a `schemaVersion` on the engine's top-level payloads, bumped
  whenever the contract changes (invariant 8 already re-captures fixtures on any output change), and
  a major-version check in `decode` that refuses an unsupported major and surfaces it as
  `DustlessError.unreadableOutput` instead of a half-decoded report.

## 6. Privilege escalation via the sudoers helper

- **Asset:** root on the machine.
- **Attack:** get the installed sudo rule to allow a command other than the ones the toggle needs,
  so a passwordless root command is available to anyone who can run the engine.
- **Mitigation:** the installed rule is exactly the steps the engine runs, derived from them and
  never written out a second time — `netPrivilege` (`src/core/net/privilege.ts`) builds from the
  command steps, `awdlPrivilege` (`src/core/net/awdl.ts`) names exactly `${IFCONFIG} ${AWDL_INTERFACE}
  up` and `down`. `sudoersArg` refuses an argument containing `"`, `#`, `*`, `?`, `[`, `]`, `\` or a
  newline — a wildcard or comment starter is refused, never escaped — and `validSudoersUser` refuses
  a name that is not `[A-Za-z0-9._-]{1,32}`, a leading `-`, `.`, `..` or `ALL`. The file is validated
  with `visudo -cf` before it is installed. `tests/net.test.ts` pins the derived rule and its
  absolute paths.
- **Residual risk:** the rules are `NOPASSWD` and live in `/etc/sudoers.d`, so any process that can
  already act as the user can run exactly those commands without a prompt. That is the intended cost
  of the toggle, and the commands change only the interface state they name.

## 7. Telemetry and accounts

- **Asset:** none held by Dustless.
- **Attack:** none — there is no channel to attack.
- **Mitigation:** a non-goal. There is no telemetry, no account and no upsell (invariant 3). This
  states what the product does, not that the machine is isolated.
- **Residual risk:** none from Dustless by construction.
