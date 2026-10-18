# Changelog

## Unreleased

### Security

- The red-list check now resolves a path's real target before every delete guard (`isRedReal` in `src/core/paths.ts`, used by `apply`, `largefiles --delete` and the MCP delete guard), so a path that reaches a red directory through a symlinked component — `~/projs/portal/canary.txt` where `portal` links to `~/Documents` — is refused instead of followed. Locked by `tests/e2e/redlist-realpath.test.ts`.
