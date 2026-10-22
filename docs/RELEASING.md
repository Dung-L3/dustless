# Releasing

The release is produced by `.github/workflows/release.yml`. Nothing about it is manual: the workflow builds
every artifact, smoke tests each one, signs what it can sign, checksums the result, and publishes.

## Before the tag

1. The version in `package.json` is the single source of truth. Bump it in the release pull request.
2. `CHANGELOG.md` gets a heading for that version, and the three READMEs mention it. The `guard` job of
   the release workflow fails the release when any of the four disagree with the tag, and
   `scripts/check-release-artifacts.ts` fails it when a README, the Windows installer or a packaging script
   names a different version.
3. Merge the release pull request into `main` and wait for `verify`, `lint`, `swift`, `macos-build` and the
   `ui` job to be green.

## What the workflow does

| Job | What it proves |
| --- | --- |
| `guard` | the tag exists on the remote, the tag, `package.json`, `CHANGELOG.md` and the three READMEs agree |
| `prepare` | the credential situation is known: a Developer ID without notary credentials fails the release here |
| `build` | the four engine binaries are built, run on a runner that can execute them, and print the released version |
| `bundle-macos` | the app bundle and the disk image are built and checked on every release run, credential or not |
| `sign-macos` | the app is signed with the Developer ID, notarised, stapled and accepted by `spctl` |
| `bundle-windows` | the installer and the portable archive are installed, run and uninstalled before they ship |
| `checksums` | every published file is listed in `SHA256SUMS` and the file verifies |
| `release` | the assets are published and the notes say what a reader will get |

### The two macOS jobs

`bundle-macos` always runs. It builds `Dustless.app`, checks that the embedded engine is the engine that is
published and answers `version` with the released number, builds the disk image, mounts it, checks that the
app and the `/Applications` symlink are inside it, unmounts it, and uploads the result as the
`dustless-macos-unsigned` artifact. It needs no credential, so the packaging path is never left
unexercised because a credential is missing.

`sign-macos` runs only when a credential exists. It signs the bundle with the Developer ID, builds the disk
image again, notarises it, staples the ticket on the image and on the app, and asserts that `spctl` accepts
the app. It uploads the result as the `dustless-macos-app` artifact.

The `checksums` job publishes the disk image **only** from `dustless-macos-app`. The unsigned image is never
published, because an app that macOS refuses to open is not a release. If `sign-macos` is skipped there is
no macOS app in the release, and the notes say so.

The rule the pipeline keeps: a release either carries a notarised macOS app or carries no macOS app at all.
It never carries an app that Gatekeeper would block, and it never skips the packaging path because a
credential is missing.

## Publishing

```sh
git tag v0.5.0
git push origin v0.5.0
```

The tag starts the release workflow. It produces:

| Artifact | Built by |
| --- | --- |
| `dustless-macos-arm64`, `dustless-macos-x64` | the `build` job, smoke tested on `macos-latest` |
| `dustless-linux-x64` | the `build` job, smoke tested on `ubuntu-latest` |
| `dustless-windows-x64.exe` | the `build` job, smoke tested on `windows-latest` |
| `Dustless-<version>.dmg` | the `sign-macos` job, notarised, stapled and accepted by `spctl` |
| `Dustless-<version>-setup.exe` | the `bundle-windows` job, installed, run and uninstalled in CI before it ships |
| `dustless-<version>-windows-x64.zip` | the `bundle-windows` job |
| `SHA256SUMS` | the `checksums` job, verified with `sha256sum -c` before publishing |

Every published file is listed in `SHA256SUMS`. To check a download:

```sh
shasum -a 256 -c SHA256SUMS
```

A workflow dispatch can republish an existing tag, but it must name the tag explicitly - the input is used,
not ignored.

## Signing and notarisation

The macOS bundle is ad-hoc signed by default and is **not** notarised, because the project holds no Apple
Developer ID. An ad-hoc app is fine on the machine that built it and is refused by Gatekeeper everywhere
else.

The moment the credentials exist, the pipeline signs with the Developer ID, notarises the disk image with
`xcrun notarytool submit --wait`, staples the ticket on the image and on the app, and asserts
`xcrun stapler validate` and `spctl -a -t exec` before anything is published. The exact secret names, and
what each one holds, are in `docs/PACKAGING.md`.

The release notes are written from what the `sign-macos` job actually did, not from what was intended: the
`macos-release.json` record carries the mode and the notarisation state, and the publish step refuses to
publish an app that is not notarised.

The Windows installer is unsigned, so SmartScreen asks the user to confirm. Both facts are stated in
`docs/PACKAGING.md` and in the release notes.

## An older release with a known problem

A published release is never rewritten: the tag, the binaries and the checksums stay exactly as they were
published, so the history of what shipped stays readable. What changes is the **warning**.

When a later audit finds a data loss risk in a published release, the release notes of that release get a
warning at the top that says what the defect is, what it does, and which version fixes it. The README says
the same thing next to the download instructions, in the three languages.

The v0.3.0 release carries such a warning: a rule whose path reaches the direct children of `$HOME` can be
created and then lists those children as reclaimable, and `apply` removes them permanently. v0.5.0 fixes it.

## After the tag

1. Confirm the release page lists every artifact and that `SHA256SUMS` matches.
2. Read the release notes: they say whether the macOS app is notarised or absent.
3. If an artifact is wrong, fix the code, cut a new patch tag, and delete the broken release. Never replace
   the binaries of a published tag with different content.
