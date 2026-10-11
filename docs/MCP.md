# Dustless as an MCP server

Dustless ships an MCP server so your own AI agent — Claude Code, opencode, Cursor, anything that speaks MCP — can inspect and clean developer caches **without you clicking through a UI**.

The whole point is that an agent calling "delete stuff" is exactly where a bug becomes data loss. So the server is built to refuse by default:

- `scan` is read-only. It can never delete anything.
- `apply` deletes **nothing** unless you pass `confirm: true`. Omit it and you get a refusal plus the exact plan.
- Red-path protection (Keychain, Mail, iCloud, `.git`, Documents, Desktop, Pictures, SQLite WAL) is hard-coded and re-exported. No parameter turns it off.
- Anything whose cross-verification failed is reported as `BLOCKED` and refused, never silently skipped.
- A hard 50 GB cap per call, only raisable with `allow_large: true` — which still requires `confirm: true`.
- `apply` is all-or-nothing: one unknown rule id or one blocked path refuses the entire call, and the response lists every problem.

## Running it

```sh
dustless mcp
```

The server speaks newline-delimited JSON-RPC 2.0 on stdin/stdout. Zero dependencies, no HTTP, no port. It is implemented directly against the MCP stdio transport.

> **stdout is the protocol channel.** Anything printed to stdout corrupts the stream. The server rebinds every `console.*` method to stderr at startup, so a stray log line anywhere in the dependency graph cannot break it.

From a checkout without building:

```sh
bun run src/cli.ts mcp
```

Verify it by hand:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}' \
  | dustless mcp
```

You should get back a single line of JSON with `serverInfo.name` of `dustless`. One wart to know about: `serverInfo.version` is hardcoded to `"0.1.0"` in `src/mcp/server.ts:10`, so it does **not** track `package.json` the way `dustless version` does. Trust `dustless version` for the real number.

## Client configuration

Replace `/absolute/path/to/dustless` with wherever the binary or checkout lives. If `dustless` is already on your `PATH`, the short form works and is preferable.

### Claude Code

```sh
claude mcp add dustless -- dustless mcp
```

Or commit a project-scoped `.mcp.json`:

```json
{
  "mcpServers": {
    "dustless": {
      "command": "dustless",
      "args": ["mcp"]
    }
  }
}
```

Without the binary on `PATH`:

```json
{
  "mcpServers": {
    "dustless": {
      "command": "bun",
      "args": ["/absolute/path/to/dustless/src/cli.ts", "mcp"]
    }
  }
}
```

### opencode

`opencode mcp add <name> -- <command…>` writes the entry for you:

```sh
opencode mcp add dustless -- dustless mcp
```

Or by hand in `opencode.jsonc`. In opencode v2 the `mcp` key **is** the map of servers: there is no `servers` wrapper, and a config that nests one is silently ignored — `opencode mcp list` reports no servers at all.

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "dustless": {
      "type": "local",
      "command": ["dustless", "mcp"],
    },
  },
}
```

Without the binary on `PATH`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "dustless": {
      "type": "local",
      "command": ["bun", "/absolute/path/to/dustless/src/cli.ts", "mcp"],
    },
  },
}
```

Check what actually landed with `opencode mcp list`.

### Cursor

`~/.cursor/mcp.json`, or `.cursor/mcp.json` for a single project:

```json
{
  "mcpServers": {
    "dustless": {
      "command": "dustless",
      "args": ["mcp"]
    }
  }
}
```

### VS Code

`.vscode/mcp.json`:

```json
{
  "servers": {
    "dustless": {
      "type": "stdio",
      "command": "dustless",
      "args": ["mcp"]
    }
  }
}
```

### Any other MCP client

Every MCP client wants the same three things: a command, its arguments, and the stdio transport. If it does not support stdio, it cannot use this server — there is no HTTP mode on purpose, because a cleanup tool should not be reachable over the network.

| Field | Value |
| --- | --- |
| Transport | stdio |
| Command | `dustless` |
| Args | `["mcp"]` |
| Protocol version | `2025-06-18` (also accepts `2025-03-26` and `2024-11-05`) |

## Tools

| Tool | Reads | Writes | Notes |
| --- | --- | --- | --- |
| `scan` | yes | no | Compact per-rule summary plus tier totals. Optional `rule_id`, `min_bytes`, `roots`. |
| `apply` | yes | **yes** | Refuses without `confirm: true`. Params `rule_ids`, `tier`, `confirm`, `allow_large`. |
| `list_rules` | yes | no | The rule database with tiers and descriptions. |
| `free_space` | yes | no | Free / total / used bytes. |
| `doctor` | yes | no | Environment diagnostics and the safety limits in force. |

Results come back both as human-readable text and as `structuredContent`, so the agent can reason about the numbers without parsing prose.

## A real conversation

**You:** how much space is my npm cache eating?

**Agent:** calling `scan` now.

```
-> tools/call  {"name":"scan"}
<- Dustless scan - mac, 1840ms, 7 of 7 findings. Nothing was deleted.

   rule_id                tier    items  size    path
   ---------------------  ------  -----  ------  --------------------------------
   gradle.version_cache   green       3  41.2 GB ~/.gradle/caches/8.12 (+2 more)
   npm.cacache            green       1   2.7 GB ~/.npm/_cacache
   bun.cache              green       1  884 MB  ~/.bun/install/cache
   BLOCKED yellow         yellow     2   9.1 GB  ~/Library/Developer/...
```

**You:** clear the npm cache.

**Agent:** the plan is 2.7 GB from `npm.cacache`, tier green, nothing blocked in that rule. Let me get the exact plan back first so you are approving a real number.

```
-> tools/call  {"name":"apply","arguments":{"rule_ids":["npm.cacache"],"tier":"green"}}
<- REFUSED - nothing was deleted.

   - confirmation: Refusing to delete: confirm is not exactly true, so this call
     is a refusal and nothing was removed. ...

   1 finding(s), 2.7 GB, would be deleted once every problem above is resolved.

   Apply is all-or-nothing. Fix every problem, then re-send the identical request
   with confirm: true.
```

**You:** yes, 2.7 GB is fine.

**Agent:** re-sending the identical request with `confirm: true`.

```
-> tools/call  {"name":"apply","arguments":{"rule_ids":["npm.cacache"],"tier":"green","confirm":true}}
<- Deleted 1 of 1 finding(s). Freed 2.7 GB in 310ms.
```

Note the order: the agent asked for the plan first, got a refusal that carried the exact byte count, showed that to you, and only then re-sent the *identical* request with `confirm: true`. That ordering is the intended shape, and the tool description tells the model to do it that way.

## When something looks wrong

- **"Server not responding."** Run `dustless doctor` through the MCP client first. If that fails, the binary is not on the `PATH` the client is using.
- **"Malformed Request" / parse errors.** Something wrote to stdout. Dustless rebinds `console.*` to stderr on startup, so this usually means a wrapper script or a shell profile is echoing. Check `dustless mcp` by hand with `echo ... | dustless mcp` and confirm you get exactly one JSON line.
- **"Refusing to delete ... over the hard agent cap of 50 GB."** Split the request into smaller batches of `rule_ids`, or approve `allow_large: true`.
- **"FAILED verification, so it is hard-blocked."** Dustless could not confirm the cache is unused. That is the cross-verification working, not a bug. Fix the underlying cause — an uncommitted change, a Gradle version a project still uses — then scan again.

## Permissions

You can further restrict what the agent may do. opencode registers an MCP tool under
`<server>_<tool>`, so a Dustless apply call is the tool `dustless_apply`, and its `permission` map
keys on tool names with `ask`, `allow` or `deny`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "dustless_scan": "allow",
    "dustless_apply": "ask"
  }
}
```

To take it away entirely rather than prompt, use the `tools` map instead, which disables a tool by
name and understands globs:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "tools": { "dustless_apply": false }
}
```

Keeping `apply` behind `ask` while the read-only tools stay free is the recommended setup: the agent
can scan freely and still cannot delete without a human in the loop. See
[the opencode permissions docs](https://opencode.ai/docs/permissions/) for the current schema — the
legacy `tools` boolean form is deprecated in favour of `permission`.
