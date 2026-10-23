# Packaging

This document is the contract between the build scripts and the person who installs the result. It says
what is built, what is checked, what is signed, and what the user has to do on their own machine.

Everything is scripted under `scripts/`. The build steps are wired into `package.json`. All steps are
idempotent — safe to run twice — and every script leaves behind one self-check so a broken build fails
loudly instead of silently shipping.

## What is shipped

| Artifact | Who it is for | Built by |
| --- | --- | --- |
| `dustless-macos-arm64`, `dustless-macos-x64` | the command line engine on macOS | the release `build` job |
| `dustless-linux-x64` | the command line engine on Linux | the release `build` job |
| `dustless-windows-x64.exe` | the command line engine on Windows | the release `build` job |
| `dustless-<version>-windows-x64.zip` | a portable Windows archive | the release `bundle-windows` job |
| `Dustless-<version>-setup.exe` | a per user Windows installer | the release `bundle-windows` job |
| `Dustless-<version>.dmg` | the macOS app, a drag to install disk image | the release `sign-macos` job |
| `SHA256SUMS` | the checksum of every published file | the release `checksums` job |

The disk image is published **only** when it can be notarised. See
[Notarisation](#notarisation-what-a-maintainer-must-provide).

## Prerequisites

- **Bun** (`>=1.3.0`) — builds the CLI engine and cross-compiles the Windows exe.
- **Swift** via CommandLineTools (no full Xcode) — builds the SwiftUI shell.
- **`hdiutil`**, **`codesign`**, **`plutil`**, **`sips`**, **`security`** — macOS built-ins, always present.

All of them are present on a stock macOS machine with CommandLineTools installed.

## Commands

```sh
bun scripts/icons.ts   # icon set -> dist/icons/ (run once on a clean checkout)
bun run build         # CLI engine -> dist/dustless (macOS arm64)
bun run bundle:mac    # SwiftUI app -> dist/Dustless.app
bun run dmg           # drag-to-install image -> dist/Dustless-<version>.dmg
bun scripts/notarize-macos.ts  # submit, staple and assert the image (needs credentials)
bun run package:win   # portable zip -> dist/dustless-<version>-windows-x64.zip
bun run installer:win # NSIS setup -> dist/Dustless-<version>-setup.exe (needs makensis)
bun run package       # runs the four build steps, best-effort
bun run lint          # repository policy: no comments, file size, unused localization keys
```

`bun scripts/icons.ts` is not wired into `package.json` and is deliberately
explicit: `dist/` is gitignored, so a clean checkout has no `dist/icons`, and
`bundle:mac` fails loudly rather than shipping an app with no icon.

`bun run package` runs every build step even if one fails and prints a pass/fail
summary; it exits non-zero only if a step failed.

`bun run lint` enforces the rules this repository documents for itself: no
comments in code, the 500 line ceiling on logic files, no localization key that
is never used, and no growth in the `path:line` references inside the docs.
`bun scripts/check-repo.ts --write-baseline` rewrites the recorded baseline.

## The app bundle — `dist/Dustless.app`

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
signature is taken, and read back with `plutil -p` afterwards so a key that was
dropped by a typo is caught.

### `Info.plist`

| Key | Value |
| --- | --- |
| `CFBundleIdentifier` | `dev.dustless.mac` |
| `CFBundleName`, `CFBundleDisplayName` | `Dustless` |
| `CFBundleExecutable` | `Dustless` |
| `CFBundlePackageType` | `APPL` |
| `CFBundleShortVersionString` | the version in `package.json` |
| `CFBundleVersion` | the version in `package.json` |
| `CFBundleIconFile` | `Dustless.icns` |
| `LSApplicationCategoryType` | `public.app-category.utilities` |
| `LSMinimumSystemVersion` | `14.0`, matching the package's `.macOS(.v14)` deployment target |
| `NSHighResolutionCapable` | `true` |

There is deliberately **no `LSUIElement`**, and the build asserts its absence. The app is a normal app —
Dock icon, app menu bar, ⌘Tab — and the menu-bar-only shape is a runtime choice: Settings → General →
**Show in Dock** flips `NSApp.setActivationPolicy` between `.regular` and `.accessory`. A plist key cannot
be changed after launch and would have forced a reinstall to switch back, and the menu-bar item works under
either policy.

### The embedded engine is the engine that is published

The engine is placed at `Contents/Resources/dustless`, which is the first path
`BinaryLocator` searches (`Bundle.main.resourceURL`). The layout matches what
the Swift code looks for.

The bundle does not trust that the file it copied is the file that was built.
It checks:

1. the SHA-256 of the engine it was given and the SHA-256 of the copy inside the
   bundle are equal, so a stale engine cannot be shipped;
2. the engine inside the bundle is `arm64` (`lipo -archs`), and so is the app
   executable;
3. the engine inside the bundle answers `version` with the same number as
   `package.json`, and so does the engine it was copied from.

A bundle that reports 0.5.0 while the engine inside it says 0.4.0 is a lie, and
the build stops.

Which engine goes in is a decision, not a guess: `DUSTLESS_ENGINE` names the
file. The release workflow downloads the `dustless-macos-arm64` artifact that
the `build` job produced and points `DUSTLESS_ENGINE` at it, so the app embeds
the very binary that is published next to it.

### The menu bar image

`Assets/MenuBarIcon.png` is a template image. The build decodes the PNG that is
inside the bundle and refuses it unless all of this holds:

- it has an alpha channel, so macOS can tint it;
- it is greyscale, so the tint is the only colour it ever shows;
- it has more than one distinct pixel value and at least one transparent pixel,
  so it is a drawn mark and not a filled rectangle.

A solid square in the menu bar is a packaging defect, not a style choice.

### Signing — two paths, and the script says which one ran

**Ad hoc** (no credential anywhere): `codesign --force --deep --sign -` and then
`codesign --verify --deep`. Both must succeed; a failed signature is a hard
error. The build prints `ad-hoc signed (no Developer ID, so Gatekeeper will
block it)`.

**Developer ID** (a credential is present): the nested code is signed first and
the bundle afterwards, with `--options runtime --timestamp`, then verified with
`codesign --verify --deep --strict`. The build prints the identity it signed
with.

The choice is made by the environment, never by the machine:

| Variable | Meaning |
| --- | --- |
| `DUSTLESS_SIGN_MODE` | `auto` (default), `adhoc` or `developer-id` |
| `MACOS_SIGNING_CERT` | the base64 of a `.p12` holding the Developer ID certificate and its private key |
| `MACOS_SIGNING_CERT_PASSWORD` | the passphrase of that `.p12` |
| `MACOS_SIGNING_IDENTITY` | optional, the exact `Developer ID Application: ... (TEAMID)` to use |

With `MACOS_SIGNING_CERT` and `MACOS_SIGNING_CERT_PASSWORD` set, the script
imports the certificate into a throwaway keychain, unlocks it, gives `codesign`
access to the key without a prompt, signs, and removes the keychain again. With
`DUSTLESS_SIGN_MODE=developer-id` a missing certificate is an error, not a
silent fall back to ad hoc.

`dist/macos-release.json` records what happened: the mode, the identity, the
team, the notarisation state and the submission id.

## The disk image — `dist/Dustless-<version>.dmg`

The image is built by `bun run dmg`, which:

1. stages `Dustless.app` with `ditto` and adds an `/Applications` symlink;
2. checks that `ditto` carried the signature into the staged bundle, then
   verifies the engine again inside the filled image by checksum against the
   bundled engine (see step 5 of the fill loop below);
3. creates an explicit-size `HFS+` staging image — the staged tree plus 96 MiB
   of slack — and fills it with `ditto` plus the Applications link;
4. converts it to compressed `UDZO` and runs `hdiutil verify` over it;
5. reads the size the image claims with `hdiutil imageinfo` and refuses it when
   it cannot hold the staged tree or when it is more than 5 percent larger than
   the size the recipe asked for — an image only works when its advertised size
   reconciles with what was requested;
6. mounts the image read-only, and checks that `Dustless.app` is there, that
   `Applications` is a symlink pointing at `/Applications`, that the app in the
   image is still signed, and that the engine inside the image answers `version`
   with the released number;
7. unmounts the image, and a failed unmount fails the build.

The volume is named `Dustless`, so it opens as `/Volumes/Dustless`.

## Notarisation: what a maintainer must provide

Nothing in this repository can substitute for an Apple Developer ID. The moment
a credential exists, the release pipeline signs, notarises, staples and asserts
the result, and the release notes say so.

The GitHub secrets the `sign-macos` job reads:

| Secret | Meaning |
| --- | --- |
| `MACOS_SIGNING_CERT` | the base64 of the Developer ID `.p12` (certificate **and** private key) |
| `MACOS_SIGNING_CERT_PASSWORD` | the passphrase of that `.p12` |
| `MACOS_SIGNING_IDENTITY` | optional, the identity to use when the `.p12` holds more than one |
| `MACOS_NOTARY_KEY_ID` | the App Store Connect API key id |
| `MACOS_NOTARY_KEY` | the contents of the API key `.p8`, base64 or PEM |
| `MACOS_NOTARY_ISSUER_ID` | the App Store Connect issuer id |
| `MACOS_NOTARY_APPLE_ID` | an alternative to the API key: the Apple id |
| `MACOS_NOTARY_PASSWORD` | an app specific password for that Apple id |
| `MACOS_NOTARY_TEAM_ID` | the Apple Developer team id |
| `MACOS_NOTARY_PROFILE` | an alternative to both: a `notarytool` keychain profile |

Either the API key trio, the Apple id trio, or a keychain profile is enough.
The `prepare` job refuses to continue when a Developer ID exists but no notary
credential does: a signed but un-notarised app is never published.

A profile exists only on the machine where `xcrun notarytool store-credentials`
created it. On GitHub-hosted runners no such profile can exist, so release runs
must use the API-key trio or the Apple id trio.

The notarisation itself (`bun scripts/notarize-macos.ts`):

1. refuses to run unless the bundle carries a real Developer ID signature;
2. `xcrun notarytool submit <the .dmg> --wait` and fails if Apple does not
   accept the image;
3. `xcrun stapler staple` on the image **and** on the app;
4. `xcrun stapler validate` on the app and on the image;
5. `codesign --verify --deep --strict` on the app again, because stapling must
   not break the signature;
6. `spctl -a -t exec -v <the app>` and `spctl -a -t open --context
   context:primary-signature -v <the image>`, both of which must be accepted.

The `spctl` assertion is made only for a real signature. An ad-hoc build is
*expected* to be rejected by Gatekeeper, so the build records that expectation
instead of asserting an acceptance it can never reach.

## Installing the app

### From the disk image

Open `Dustless-<version>.dmg` and drag **Dustless** into `/Applications`. The
image holds nothing else: the app and the `/Applications` shortcut.

### When the app is not notarised

An ad-hoc signed app that arrives through a browser or a chat client carries
the `com.apple.quarantine` attribute, and Gatekeeper refuses the first launch:

> "Dustless" can't be opened because Apple cannot check it for malicious software.

Either right click the app → **Open** → **Open**, or clear the attribute:

```sh
xattr -dr com.apple.quarantine "/Applications/Dustless.app"
```

A notarised app has no such step: the ticket is stapled to it and Gatekeeper
opens it without a question.

### Upgrading in place

Download the new disk image and replace the app in `/Applications`. Drag the old
app out first, or replace it in place — either way, only the bundle changes.

**Preserved:**

- the preferences, in `~/Library/Preferences/dev.dustless.mac.plist` — the
  language, the appearance and the "show in Dock" choice;
- your own rules, in `~/.config/dustless/rules.yaml` — the file the engine reads
  before the bundled rule set.

**Replaced:** the whole `Dustless.app` bundle, including the embedded engine.

Nothing outside `/Applications/Dustless.app` is written by an upgrade.

### Uninstalling

1. Drag `Dustless.app` out of `/Applications` and delete it. The menu bar item
   goes with it: it belongs to the running app, and the app is what draws it.
   There is no separate menu bar item to remove and no login item unless you
   turned one on in Settings.
2. Remove the privilege helper, if the app installed one.

#### The privilege helper

The AirDrop (AWDL) toggle and the advanced network operations need one
privileged command each. The app does not ask for your password on every use.
Instead it can install a narrow rule in `/etc/sudoers.d/dustless-awdl`:

```
<your user> ALL=(root) NOPASSWD: /sbin/ifconfig awdl0 down, /sbin/ifconfig awdl0 up
```

That rule does exactly two things and nothing else: it lets the app turn the
`awdl0` interface down and up, as root, without asking for a password. It is
written with mode `0440`, owned by `root:wheel`, and it is checked with `visudo`
before it is installed. The network panel installs a second, equally narrow rule
in `/etc/sudoers.d/dustless-net` for four network commands.

Remove them from inside the app: Settings → **Remove permission** for the
AirDrop rule, and the Network panel → **Forget** for the network rule. Both ask
for the administrator password once and delete the file.

By hand, if the app is already gone:

```sh
sudo rm -f /etc/sudoers.d/dustless-awdl
sudo rm -f /etc/sudoers.d/dustless-net
```

Those two commands delete the rule files above. They do not change anything
else, and they do not remove a user, a password or any other sudoers rule. Read
the file before you delete it if you want to see what it allowed:

```sh
cat /etc/sudoers.d/dustless-awdl
```

Nothing in `/etc/sudoers.d` is touched by an install or an upgrade, only by the
two actions above.

## Telling a notarised build from an ad-hoc one

```sh
codesign -dv --verbose=4 "/Applications/Dustless.app" 2>&1 | grep -E "Authority|Signature"
```

- A **notarised** build prints an `Authority` line with a `Developer ID
  Application:` name and a `TeamIdentifier`, and `spctl -a -t exec -v
  "/Applications/Dustless.app"` says `accepted`.
- An **ad-hoc** build prints `Signature=adhoc`, no `Authority`, and `spctl`
  rejects it.

The stapled ticket is visible too:

```sh
xcrun stapler validate "/Applications/Dustless.app"
```

The difference is what the user has to do: a notarised app opens without a
warning and without an administrator password, an ad-hoc app asks the user to
clear the quarantine attribute once.

## The command line binary and the app are not the same thing

The app is **not** a wrapper around the command line binary. It embeds its own
copy of the engine at `Contents/Resources/dustless` and runs that.

| | `dustless` on your `PATH` | `Dustless.app` |
| --- | --- | --- |
| What it is | the compiled engine | a SwiftUI app that embeds the engine |
| Settings | none; it is a process | its own domain, `dev.dustless.mac` |
| Menu bar item | no | yes |
| Can ask for an administrator password | never | yes, through the scoped sudo rule |
| Where the rules come from | `~/.config/dustless/rules.yaml` | the same file, through the embedded engine |

**Which one should you install?** The engine, if you want the tool on your
`PATH` for a terminal, a script or an editor. The app, if you want the menu bar
item, the panels and the one-time permission without a password.

Install one or both. They do not conflict: they read the same rules file, and
the app does not replace or shadow the binary on your `PATH`.

They report the same version. The engine prints the version in `package.json`,
the app carries the same number in `Info.plist`, and the engine inside the app
prints it again. `bun scripts/check-release-artifacts.ts <tag> --artifacts`
fails the release when any of the three disagrees.

## Release consistency

`bun scripts/check-release.ts <tag>` fails the release when the tag,
`package.json`, `CHANGELOG.md` and the three READMEs disagree.

`bun scripts/check-release-artifacts.ts <tag>` fails the release when anything
else drifts: when a README names a version that is not the one being released,
when a packaging script or the Windows installer hardcodes a version instead of
reading `package.json`, and — with `--artifacts` — when the built engine, the
`Info.plist` or the embedded engine answers with a different number than the
tag.

The release workflow runs the first in its `guard` job and the second in the
same job and in the `bundle-macos` job.

## Notes

- `dist/` is gitignored; the scripts only write inside `dist/` and stage in the
  system temporary directory.
- All scripts are idempotent: they remove their own previous output before
  regenerating it.
- `bun run typecheck` covers `src`, `tests`, and `scripts` (strict mode).
- The version is `package.json`. Nothing else in the repository carries a
  version literal, and the release checks make sure that stays true.
