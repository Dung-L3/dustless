# Web UI test report

`bun test tests/e2e-ui` — no browser, no devtools, no keychain.

**Result: 60 pass, 9 fail, 0 skip.** All 9 failures are real defects in `src/`, not test bugs. Each one
is listed below with what it expected, what it actually got, and the evidence.

## What replaced the browser

The previous suite drove Brave over the DevTools Protocol. That is gone: `cdp.ts` and `suite.ts` are
deleted, nothing in the repo launches a browser, and `docs/TESTING.md` records why it must stay gone
(the browser profile path makes macOS prompt for the login keychain on the user's real Brave
profile). The screenshots that run produced were untracked and were lost before this rewrite landed,
so there is nothing to keep.

The surface is now tested in four layers, none of which needs pixels:

| File | Layer | What it pins down |
| --- | --- | --- |
| `i18n.test.ts` | DOM-free unit | vi/en/zh key parity, placeholder parity, no untranslated strings, every `t("…")` and `data-i18n` key exists |
| `contract.test.ts` | static text | id/selector contract between `app.js` and `index.html`, zero off-origin URLs, CSP-compatible markup, reduced motion, tier colour distance, accessible names |
| `app.test.ts` | hand-written DOM stub | the real `app.js` running against a synthetic `ScanReport` with a GREEN, a YELLOW and a BLOCKED finding |
| `server.test.ts` | real HTTP | routes, content types, 404/400/413, 403 on a spoofed `Host`, loopback-only bind, all-skip apply deletes nothing, blocked findings survive |

## The highest-value regression test

> `apply is inert unless the payload says so > an all-skip payload deletes nothing and frees nothing`

It POSTs `{tiers: {<every rule in the live scan>: "skip"}}` at a real server whose `HOME` is a
throwaway `mkdtemp` sandbox, then asserts three things: every outcome is `skipped`, `freed` is `0`,
and a sha256 fingerprint over every path, size and byte of the sandbox is byte-identical to the
fingerprint taken before the request.

It is not vacuous. Verified by mutation: a probe that sends `{"npm.cacache": "green"}` instead
produces a `deleted` outcome and a **different** fingerprint, so the same helper detects a real
deletion. If the product ever stopped honouring `skip`, or started deleting on a read, or picked a
path outside the sandbox, this is the test that fails.

## Failing checks — all product bugs

### 1-6. A blocked finding is sold to the user as deletable

`scan.ts` marks a finding `blocked: true` **and** downgrades `tier` to `"yellow"`; `tally()` books it
under `totals.blocked`, never `totals.yellow` or `totals.green`. `app.js` only ever looks at
`finding.tier`. It never reads `finding.blocked` anywhere. The row therefore renders as an ordinary
yellow item with a live Delete/Keep switch, it is counted into the hero figure, and it is listed in
the confirmation dialog as a file that is about to be deleted.

| Test | Expected | Actual |
| --- | --- | --- |
| the blocked row carries the localised blocked label, not colour alone | text contains `Hard-blocked by the safety list` | `…8.14Your callnot verified45d oldKHÔNG XÓA: project /Users/dev/work/app uses Gradle 8.146 MBDeleteKeepWill be deleted when you confirm` |
| the blocked row is rendered as blocked, not as a yellow item | `data-tier` ≠ `yellow` | `data-tier=yellow` |
| the blocked row never gets a delete control | no `.switch button[data-choice=delete]` | `hasDelete: true, aria-pressed: "true"` |
| the blocked row is left out of the delete selection | `data-chosen=false` | `data-chosen=true` |
| the reclaimable figure equals what the server says is reclaimable | `20971520` (20 MiB) | `27262976` (26 MiB) — the blocked 6 MiB are counted as reclaimable |
| the blocked tier card counts the blocked findings | `redCount` = `1` | `redCount` = `0`; the card is wired to `totals.red.count`, which `scan.ts` can never populate because `candidates()` drops every red-list path, so the "Blocked" card is structurally always zero |
| a rule holding a blocked finding is never asked to delete | `{"ruleId":"gradle.version_cache","requested":"skip"}` | `{"ruleId":"gradle.version_cache","requested":"yellow"}` — this is the payload `app.js` POSTs to `/api/apply` |

**The data is still safe; the UI is not.** `apply()` checks `finding.blocked` before it touches the
filesystem and returns `skipped`, which
`server.test.ts > a blocked finding survives even when the ui asks for its rule` proves by asking the
server to delete every single rule and finding the blocked file still on disk. So the defect is a
representation lie, not a data-loss bug: the headline number over-promises, the dialog lists a file
that will never be deleted, and the only honest signal on the row is an untranslated backend note
sitting next to a Delete button.

Root cause worth fixing: the UI's decision model is keyed by `ruleId` (`declinedRules`,
`tierChoices()`, the `ruleWide` label all say so) while the safety decision is per-finding. As long
as one rule can mix blocked and unblocked findings, no per-row control can be honest. Either the API
needs a per-finding or per-path choice, or `tierChoices()` has to refuse to send `yellow` for any
rule that owns a blocked finding.

### 7. `POST /api/apply` accepts a cross-origin request

| Test | Expected | Actual |
| --- | --- | --- |
| a cross-origin post cannot reach the delete path | `>= 400` | `200`, apply ran |

Sent with `Origin: http://evil.example.com` and `Content-Type: text/plain`, which makes it a CORS
simple request: no preflight, no `Access-Control-Allow-Origin` needed for the *write* to happen.
Any web page the user visits can POST `{"tiers": {"npm.cacache": "green"}}` to
`http://127.0.0.1:4477/api/apply` and the browser will happily delete the user's caches. The Host
check does not help — the browser sets `Host: 127.0.0.1:4477` itself. The test asserts `>= 400` and
uses an all-skip payload, so it proves reachability of the write path without deleting anything
(the fingerprint assertion in the same test confirms the sandbox is untouched).

Fix: reject any request whose `Origin` is present and not `http://127.0.0.1:<port>`, or require a
custom header that a cross-origin simple request cannot set. `Sec-Fetch-Site` is the cheap option.

### 8. An oversized body returns `200` with an empty body

| Test | Expected | Actual |
| --- | --- | --- |
| an oversized body returns 413 with a json error | `413` + `application/json` + `{error}` | `200`, `content-type: null`, empty body |

`readChoices()` throws `HttpError(413, "request body too large")` from inside the `for await` over
the request, which tears the request stream down before the handler can answer; the client is left
with a bare `200` and nothing else. Nothing is deleted (the fingerprint assertion in the same test
proves it), but the UI's `api()` will surface the error string `HTTP 200` to the user instead of
"request body too large". Drain or destroy the socket deliberately and answer with the 413.

## Not testable without a browser

Nothing below is run. Each one needs a real rendering engine, and the browser route is closed.

1. Rendered layout at any viewport — no horizontal-overflow check at 1280×800 or 1024×700, no "CTA is
   not clipped", no measurement of anything.
2. Real CSS cascade results — computed colours, opacity, display, z-order. The tier palette is only
   checked as declared values in `style.css`, not as painted pixels.
3. Per-control focus outlines and the visible focus ring while tabbing. Only the presence of a
   `:focus-visible { outline: … }` rule is asserted.
4. Dialog focus behaviour — focus trap across tabs, `Esc` to cancel, focus returning to `#cleanBtn`
   on close. The stub has no focus model.
5. Console and network capture — zero console errors, zero uncaught exceptions, zero failed
   requests during a real load. The stub makes any throw surface as a failing test, but it does not
   observe a real page's console.
6. Screenshots. The evidence images from the old run are gone; nothing regenerates them.
7. `prefers-reduced-motion` behaviour as a *user setting*. The CSS media query and the
   `matchMedia` call in `app.js` are asserted to agree; neither branch is exercised in a real engine.

## Coverage limits, stated plainly

- The DOM stub models about a third of the DOM: no layout, no focus, no events beyond click
  bubbling, no `<dialog>` semantics, no CSS. It is good enough to test `app.js`'s logic and not good
  enough to claim anything about how the page looks.
- The server suite exercises a handful of rules planted in a sandbox. It is not a rules-coverage
  test; `tests/e2e` already covers the CLI against the compiled binary.
- The static contract tests are regex over source text. They will catch a rename and they will not
  catch a semantic change.
- The 413 finding above is the only test whose failure mode is a broken client contract rather than a
  product promise. Everything else in the failing list is the product telling the user something
  untrue about what will happen to their files.

## Sandboxing

Every command that can delete runs in a child process with `HOME` pointed at a fresh `mkdtemp`
sandbox and `XDG_CONFIG_HOME` redirected into it. `assertInsideSandbox()` throws unless a path is
strictly under the sandbox root, and it runs over every finding path before any apply.

One correction to the assumption this suite was built on, because it nearly cost real data:
`os.homedir()` follows `$HOME` **in a child process**, but it does **not** follow
`process.env.HOME = …` mutated inside the running process — Bun still returns the OS account's
home. `src/core/paths.ts` captures `HOME = homedir()` at module load, so importing the scanner into
a test process that "set" `HOME` afterwards scans and deletes the real home. The harness spawns
`src/cli.ts ui` as a child for exactly this reason, and `server.test.ts > the sandbox HOME is what
the server scans` fails loudly if any finding escapes the sandbox.