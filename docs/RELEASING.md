# Releasing

The release is produced by `.github/workflows/release.yml`. Nothing about it is manual: the workflow builds
every artifact, smoke tests each one, signs what it can sign, checksums the result, and publishes.

## Before the tag

1. The version in `package.json` is the single source of truth. Bump it in the release pull request.
2. `CHANGELOG.md` gets a heading for that version, and the three READMEs mention it. The `guard` job of
   the release workflow fails the release when any of the four disagree with the tag.
3. Merge the release pull request into `main` and wait for `verify`, `lint`, `swift`, `macos-build` and the
   `ui` job to be green.

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
| `Dustless.app` and `Dustless-<version>.dmg` | the `bundle-macos` job, `codesign --verify` and the bundled engine are checked |
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

The macOS bundle is signed **ad hoc** and is **not notarised**, because the project holds no Apple Developer
ID. `spctl` rejects it, so a first launch from a downloaded disk image needs either

```sh
xattr -dr com.apple.quarantine "/Applications/Dustless.app"
```

or right click, Open, Open. The Windows installer is unsigned, so SmartScreen asks the user to confirm.

Both facts are stated in `docs/PACKAGING.md` and in the release notes. A Developer ID plus
`xcrun notarytool submit --wait` plus a `staple` step, with `spctl -a` asserted in CI, is the only way to
remove the warning; that needs a paid Apple Developer account and cannot be produced by this repository.

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
2. If an artifact is wrong, fix the code, cut a new patch tag, and delete the broken release. Never replace
   the binaries of a published tag with different content.
