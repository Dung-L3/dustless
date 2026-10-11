# Packaging

Build installers for the Dustless CLI and the macOS app from a single machine.

Everything is scripted under `scripts/` and wired into `package.json`. All steps
are idempotent — safe to run twice — and every script leaves behind one
self-check so a broken build fails loudly instead of silently shipping.

## Prerequisites

- **Bun** (`>=1.3.0`) — builds the CLI engine and cross-compiles the Windows exe.
- **Swift** via CommandLineTools (no full Xcode) — builds the SwiftUI shell.
- **`hdiutil`** and **`codesign`** — macOS built-ins, always present.

All four are present on a stock macOS machine with CommandLineTools installed.

## Commands

```sh
bun run build        # CLI engine -> dist/dustless (macOS arm64)
bun run bundle:mac   # SwiftUI app -> dist/Dustless.app
bun run dmg          # drag-to-install image -> dist/Dustless-<version>.dmg
bun run package:win  # portable zip -> dist/dustless-<version>-windows-x64.zip
bun run package      # runs all four of the above, best-effort
```

`bun run package` runs every step even if one fails and prints a pass/fail
summary; it exits non-zero only if a step failed.

## Artifacts (measured on macOS 26.5.1, arm64, Bun 1.3.13, Swift 6.3.2)

| Artifact | Path | Size | Command | Time |
| --- | --- | --- | --- | --- |
| Engine (macOS) | `dist/dustless` | 62,820,080 B (60 MB) | `bun run build` | ~1 s |
| Engine (Windows) | `dist/dustless.exe` | 117,773,824 B (112 MB) | `bun run package:win` | ~4 s |
| App bundle | `dist/Dustless.app` | 61 MB total | `bun run bundle:mac` | 39.6 s first / 1.6 s cached |
| Disk image | `dist/Dustless-0.1.3.dmg` | 26,526,836 B (25 MB) | `bun run dmg` | ~8–9 s |
| Windows zip | `dist/dustless-0.1.3-windows-x64.zip` | 42,147,920 B (40 MB) | `bun run package:win` | ~4 s |

Times are wall-clock. `bundle:mac` is dominated by the Swift release build
(37.8 s on first build); later runs are incremental (~0.1 s). `package:win` is
dominated by the Bun `--compile` cross-target step (~0.2 s once the runtime is
cached) plus zip compression of a 112 MB binary.

## What each script does

### `bundle:mac` — `dist/Dustless.app`

Builds the SwiftUI app (`swift build -c release`), then assembles:

```
Dustless.app/Contents/MacOS/Dustless        SwiftUI executable (arm64)
Dustless.app/Contents/Resources/dustless    CLI engine (the compiled Bun binary)
Dustless.app/Contents/Resources/Dustless.icns
Dustless.app/Contents/Info.plist
```

`Info.plist` carries `CFBundleIdentifier` (`dev.dustless.mac`),
`CFBundleShortVersionString`/`CFBundleVersion` (from `package.json`),
`CFBundleIconFile`, `LSMinimumSystemVersion` (`14.0`, matching the package's
`.macOS(.v14)` deployment target), `NSHighResolutionCapable`, and
`LSUIElement` (the app is a menu-bar utility).

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

## Windows installer route investigation

The preferred routes were checked in order and neither is available on this
machine:

1. **electron-builder → NSIS `.exe`** — not applicable. This is a native
   Bun-compiled binary, not an Electron app; packaging it with electron-builder
   would mean adding Electron plus a large dependency tree for no benefit. Not
   attempted for that reason.
2. **Inno Setup / NSIS via Wine** — not installed (`wine` and `makensis` are
   absent). Installing them is a large system-level dependency and not warranted
   for a single-file portable binary.

Therefore the portable `.zip` is the implemented, verified route. A `.zip` with
`dustless.exe` and a `README.txt` is also exactly what the project's release
workflow already ships (raw per-platform binaries), so it is consistent with
the existing distribution model.

## Notes

- `dist/` is gitignored; the scripts only write inside `dist/` and stage in
  `/tmp`.
- All scripts are idempotent: they remove their own previous output before
  regenerating it.
- `bun run typecheck` covers `src`, `tests`, and `scripts` (strict mode).
