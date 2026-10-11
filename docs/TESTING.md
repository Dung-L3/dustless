# Testing

```sh
bun run typecheck     # tsc --noEmit over src and tests
bun test              # everything, about 10s
bun run test:ui       # just the web-UI suite in tests/e2e-ui
```

No build step and no browser is needed for the UI suite. `tests/e2e` runs the compiled binary in
`dist/`, so run `bun run build` first if you have never built.

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
a throwaway directory.** `tests/e2e-ui/harness.ts` does this: `mkdtemp` a root, `mkdir home`, plant
files, spawn `bun src/cli.ts ui --port N --no-open` with `HOME` and `XDG_CONFIG_HOME` in the child's
env, and `rm -rf` the root afterwards.

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

The sandbox helper is not optional either: `assertInsideSandbox()` throws unless a path is strictly
under the sandbox root, and every finding path goes through it before any apply.

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

Nine checks in `tests/e2e-ui` fail against the current product. They are real defects, listed with
evidence in `tests/e2e-ui/REPORT.md`. Do not "fix" them by loosening the assertion, and do not edit
`src/` to make them green — that is a product decision, not a test decision.