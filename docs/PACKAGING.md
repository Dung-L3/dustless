# Packaging

Build installers for the Dustless CLI and the macOS app from a single machine.

Everything is scripted under `scripts/`; the build steps are wired into
`package.json`. All steps are idempotent — safe to run twice — and every script
leaves behind one self-check so a broken build fails loudly instead of silently
shipping.

## Prerequisites

- **Bun** (`>=1.3.0`) — builds the CLI engine and cross-compiles the Windows exe.
- **Swift** via CommandLineTools (no full Xcode) — builds the SwiftUI shell.
- **`hdiutil`** and **`codesign`** — macOS built-ins, always present.

All four are present on a stock macOS machine with CommandLineTools installed.

## Commands

```sh
bun scripts/icons.ts  # icon set -> dist/icons/ (run once on a clean checkout)
bun run build        # CLI engine -> dist/dustless (macOS arm64)
bun run bundle:mac   # SwiftUI app -> dist/Dustless.app
bun run dmg          # drag-to-install image -> dist/Dustless-<version>.dmg
bun run package:win  # portable zip -> dist/dustless-<version>-windows-x64.zip
bun run installer:win # NSIS setup -> dist/Dustless-<version>-setup.exe (needs makensis)
bun run package      # runs the four build steps, best-effort
```

`bun scripts/icons.ts` is not wired into `package.json` and is deliberately
explicit: `dist/` is gitignored, so a clean checkout has no `dist/icons`, and
`bundle:mac` fails loudly rather than shipping an app with no icon.

`bun run package` runs every build step even if one fails and prints a pass/fail
summary; it exits non-zero only if a step failed.

## Artifacts (measured on macOS 26.5.1, arm64, Bun 1.3.13, Swift 6.3.3 on 2026-10-19, at version 0.5.0)

| Artifact | Path | Size | Command | Time |
| --- | --- | --- | --- | --- |
| Engine (macOS) | `dist/dustless` | 62,787,248 B (60 MB) | `bun run build` | ~1 s |
| Engine (Windows) | `dist/dustless.exe` | 117,741,056 B (112 MB) | `bun run package:win` | ~4 s |
| App bundle | `dist/Dustless.app` | 64 MB total | `bun run bundle:mac` | 17.2 s first / 1.1 s cached |
| Disk image | `dist/Dustless-<version>.dmg` | 27,380,529 B (26 MB) | `bun run dmg` | ~7 s |
| Windows zip | `dist/dustless-<version>-windows-x64.zip` | 42,141,795 B (40 MB) | `bun run package:win` | ~4 s |

Sizes are for version 0.5.0 and move with the code; the paths take the current
`package.json` version. Times are wall-clock. `bundle:mac` is dominated by the
Swift release build (14.9 s on first build); later runs are incremental
(~1 s). `package:win` is dominated by the Bun `--compile` cross-target step
(~0.2 s once the runtime is cached) plus zip compression of a 112 MB binary;
the very first run also downloads the cross-target runtime (~2 minutes here).

## What each script does

### `bundle:mac` — `dist/Dustless.app`

Builds the SwiftUI app (`swift build -c release`), then assembles:

```
Dustless.app/Contents/MacOS/Dustless        SwiftUI executable (arm64)
Dustless.app/Contents/Resources/dustless    CLI engine (the compiled Bun binary)
Dustless.app/Contents/Resources/Dustless.icns
Dustless.app/Contents/Resources/MenuBarIcon.png
Dustless.app/Contents/Info.plist
```

Both executables are `chmod 755`, and the build **fails** rather than shipping a
crippled app if `dist/Dustless.icns` or `Assets/MenuBarIcon.png` is missing — an
app with no icon or a menu-bar mark that paints a solid square is worse than a
build that stops. `Info.plist` is passed through `plutil -lint` before the
signature is taken.

`Info.plist` carries `CFBundleIdentifier` (`dev.dustless.mac`),
`CFBundleShortVersionString`/`CFBundleVersion` (from `package.json`),
`CFBundleIconFile`, `LSMinimumSystemVersion` (`14.0`, matching the package's
`.macOS(.v14)` deployment target) and `NSHighResolutionCapable`.

There is deliberately **no `LSUIElement`**. The app is a normal app — Dock icon,
app menu bar, ⌘Tab — and the menu-bar-only shape is a runtime choice: Settings →
General → **Show in Dock** flips `NSApp.setActivationPolicy` between `.regular`
and `.accessory` (`AppSettings.applyActivationPolicy`). A plist key cannot be
changed after launch and would have forced a reinstall to switch back, and the
menu-bar item works under either policy.

The engine is placed at `Contents/Resources/dustless`, which is the first path
`BinaryLocator` searches (`Bundle.main.resourceURL`). The layout matches what
the Swift code looks for.

The bundle is ad-hoc signed (`codesign --force --deep --sign -`) and then
verified with `codesign --verify --deep`; a failed signature is a hard error.

The Swift package is located at `apps/dustless-mac`. Override with
`DUSTLESS_APP_SRC` if you build from a checkout where it lives elsewhere.

### `dmg` — `dist/Dustless-<version>.dmg`

Stages `Dustless.app` plus an `/Applications` symlink, creates a compressed
`UDZO` image with `hdiutil`, then mounts it, confirms both the app and the
symlink are present, and unmounts — all programmatically, as a self-check.

### `package:win` — `dist/dustless-<version>-windows-x64.zip`

Cross-compiles the engine with `BUN_TARGET=bun-windows-x64`, then inspects the
result before packaging it:

1. `file` must report `PE32+ executable ... x86-64, for MS Windows`.
2. `strings` import scan must show **only** Windows system DLLs
   (`KERNEL32.dll`, `ntdll.dll`, `WS2_32.dll`, `bcrypt.dll`, …) and no
   `bun`/`node`/`libuv`/`vcruntime` dependency.

The zip contains `dustless.exe` and a `README.txt`. The binary is a
Bun `--compile` output: the Bun runtime and your code are statically embedded,
so it needs no Bun, no Node, and nothing on PATH.

## Signing and notarisation — the honest story

**macOS.** There is no Apple Developer ID, so the app is only *ad-hoc* signed.
That is enough to run a locally-built app, but it is **not notarised**. When the
`.dmg` is downloaded and the app dragged to `/Applications`, macOS applies a
quarantine flag and Gatekeeper blocks the first launch with:

> "Dustless" can't be opened because Apple cannot check it for malicious software.

One-line workaround:

```sh
xattr -dr com.apple.quarantine "/Applications/Dustless.app"
```

(or right-click the app → **Open** → **Open**). Publishing without the warning
requires an Apple Developer ID and `notarytool` notarisation, which needs a paid
Apple Developer account — nothing in this repo can substitute for that.

**Windows.** The `.exe` is unsigned. On first run, Microsoft Defender SmartScreen
shows:

> Windows protected your PC — Microsoft Defender SmartScreen prevented an
> unrecognized app from starting.

Click **More info** → **Run anyway**, or remove the Mark-of-the-Web in
PowerShell:

```powershell
Unblock-File .\dustless.exe
```

Eliminating the prompt requires an Authenticode code-signing certificate, which
the project does not hold.

## Windows installer

`bun run installer:win` builds `dist/Dustless-<version>-setup.exe` with NSIS
from `packaging/windows/installer.nsi`, the compiled `dist/dustless.exe` and the
icon at `dist/icons/dustless.ico` (falling back to the committed
`brand/generated/dustless.ico`). It shells out to `makensis`, so run
`bun run package:win` first on a machine without the Windows engine.

The installer is per-user (`$LOCALAPPDATA\Programs\Dustless`), refuses anything
older than Windows 10, and ships an uninstaller.
`.github/workflows/windows-installer.yml` builds and verifies it on
`windows-latest` (NSIS is preinstalled there, with a Chocolatey fallback) on
every `v*` tag and on pull requests that touch `packaging/windows/`. That
workflow checks the MZ header and size, silently installs, runs
`dustless.exe version` and `scan --json`, uninstalls, and asserts the engine is
gone, then attaches the setup exe to the release next to the portable zip.

The portable `.zip` remains the no-installer route. There is no
electron-builder path: this is a Bun-compiled binary, not an Electron app, and
the NSIS script runs natively on Windows rather than under Wine.

## Notes

- `dist/` is gitignored; the scripts only write inside `dist/` and stage in
  `/tmp`.
- All scripts are idempotent: they remove their own previous output before
  regenerating it.
- `bun run typecheck` covers `src`, `tests`, and `scripts` (strict mode).
