# Architecture

Two languages, one product. The engine is a compiled binary; the app embeds a
copy of it and talks to it as a child process. Nothing links the two, and no
schema is shared — so the thing that keeps them in step is worth knowing about
before you change either side.

```
src/  (TypeScript, bun)  --bun run build-->  dist/dustless   (single binary)
                                                   |
                              scripts/bundle-macos.ts embeds it
                                                   v
                        Dustless.app/Contents/Resources/dustless
                                                   |
                          the app runs it and reads --json
```

## The contract, and how it is enforced

`src/types.ts` is authoritative for every payload the engine prints. The Swift
models in `apps/dustless-mac/Sources/DustlessKit/Model/` mirror them by hand;
nothing generates the Swift side.

What keeps the two honest is the fixture loop:

1. `scripts/capture-engine-payloads.ts` runs the real engine commands against
   planted caches in the test sandbox (`tests/e2e/harness.ts`) and writes
   `apps/dustless-mac/Tests/DustlessAppTests/Fixtures/*.json`.
2. `EngineContractTests.swift` decodes those fixtures with the Swift models.

So changing what the engine prints means re-running the capture and committing
the regenerated fixtures:

```
bun scripts/capture-engine-payloads.ts
```

The Swift side continuing to compile is not proof of anything — the fixtures are.

## The app never links the engine

`DustlessKit/Engine/DustlessCLI.swift` spawns the binary and decodes JSON.
`BinaryLocator` looks for it in the app bundle's resources first, then `dist/`,
then the search path, which is what makes a development run use the build in
`dist/` while a release uses the copy inside the bundle.

## Layout

| Path | What it is |
|---|---|
| `src/cli.ts` | argument parsing and dispatch; every command lives in `src/cli/` |
| `src/core/` | the work: scanning, applying, rules, paths, verification |
| `src/mcp/` | the MCP server |
| `apps/dustless-mac/Sources/DustlessKit/` | engine client, models, formatting |
| `apps/dustless-mac/Sources/DustlessApp/` | views and services |
| `tests/` | the engine's tests, including the sandboxed e2e harness |
| `apps/dustless-mac/Tests/` | the app's Swift tests and the contract fixtures |
| `scripts/` | build and release tooling |
| `docs/` | decisions (`DECISIONS.md`), testing rules, packaging, network, MCP |
| `brand/` | icon sources, and the generated icons that are committed |

## Two rules that are not style preferences

Deletion tests run in a **child process with a sandboxed `HOME`** — see
`docs/TESTING.md`. Running them in-process has deleted real data twice.

Reasoning that used to live in code comments now lives in `docs/DECISIONS.md`.
When a change alters one of those decisions, edit the entry; when it makes a new
one, add an entry.
