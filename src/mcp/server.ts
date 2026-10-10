import { createInterface } from "node:readline";
import { format } from "node:util";
import { apply } from "../core/apply.ts";
import { loadRules } from "../core/rules.ts";
import { scan } from "../core/scan.ts";
import { freeSpace } from "../core/space.ts";
import { createTools, type Core, type Tool } from "./tools.ts";

export const PROTOCOL_VERSION = "2025-06-18";
export const SERVER_INFO = { name: "dustless", version: "0.1.0" };

const SUPPORTED_PROTOCOLS = [PROTOCOL_VERSION, "2025-03-26", "2024-11-05"];
const INSTRUCTIONS = [
  "Dustless reclaims developer toolchain caches (Gradle, npm, pnpm, bun, uv, pub, Homebrew) on macOS, Windows and Linux.",
  "Workflow: doctor to verify the server, then scan (read-only) to see what is reclaimable, then apply with rule_ids.",
  "apply refuses to delete anything unless confirm is true. Show the user the plan, get explicit approval for the exact byte count, then re-send with confirm: true. Never set confirm yourself to unblock a call.",
  "Never pass a path as a rule id: apply only accepts rule ids from list_rules or scan.",
].join("\n");

type RpcId = string | number | null;
type RpcError = { code: number; message: string; data?: unknown };
type RpcMessage = { jsonrpc: "2.0"; id: RpcId; result?: unknown; error?: RpcError };

export const core: Core = { scan, apply, loadRules: () => loadRules(), freeSpace };

export function guardStdout(): void {
  const target = console as unknown as Record<string, (...args: unknown[]) => void>;
  for (const name of ["log", "info", "debug", "warn", "error", "trace", "dir", "table", "assert", "count"]) {
    target[name] = (...args: unknown[]) => {
      process.stderr.write(`${format(...args)}\n`);
    };
  }
}

export function encode(message: RpcMessage | null): string | null {
  return message === null ? null : `${JSON.stringify(message)}\n`;
}

function reply(id: RpcId, result: unknown): RpcMessage {
  return { jsonrpc: "2.0", id, result };
}

function failure(id: RpcId, code: number, message: string, data?: unknown): RpcMessage {
  return { jsonrpc: "2.0", id, error: data === undefined ? { code, message } : { code, message, data } };
}

function negotiate(requested: unknown): string {
  return typeof requested === "string" && SUPPORTED_PROTOCOLS.includes(requested) ? requested : PROTOCOL_VERSION;
}

async function callTool(id: RpcId, name: unknown, args: unknown, tools: Tool[]): Promise<RpcMessage> {
  const found = tools.find((tool) => tool.name === name);
  if (!found) {
    return failure(id, -32602, `Unknown tool "${String(name)}". Call tools/list for the available tools.`);
  }
  try {
    const params = args === undefined || args === null ? {} : args;
    if (typeof params !== "object" || Array.isArray(params)) throw new Error("params must be an object");
    return reply(id, await found.run(params as Record<string, unknown>));
  } catch (err) {
    return reply(id, {
      content: [{ type: "text", text: `${found.name} failed: ${(err as Error).message}` }],
      isError: true,
    });
  }
}

export async function handleRpc(request: unknown, tools: Tool[]): Promise<RpcMessage | null> {
  if (typeof request !== "object" || request === null || Array.isArray(request)) {
    return failure(null, -32600, "Invalid Request: the payload must be a single JSON-RPC object, not a batch.");
  }
  const raw = request as Record<string, unknown>;
  const id = typeof raw["id"] === "string" || typeof raw["id"] === "number" ? (raw["id"] as RpcId) : null;
  const method = raw["method"];
  if (raw["jsonrpc"] !== "2.0" || typeof method !== "string" || !method) {
    return failure(id, -32600, 'Invalid Request: expected {"jsonrpc":"2.0","method":string,"id":number|string}.');
  }
  if (!("id" in raw) || raw["id"] === undefined) return null;
  const params = (raw["params"] ?? {}) as Record<string, unknown>;
  switch (method) {
    case "initialize":
      return reply(id, {
        protocolVersion: negotiate(params["protocolVersion"]),
        capabilities: { tools: { listChanged: false } },
        serverInfo: SERVER_INFO,
        instructions: INSTRUCTIONS,
      });
    case "notifications/initialized":
    case "notifications/cancelled":
      return null;
    case "tools/list":
      return reply(id, {
        tools: tools.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
      });
    case "tools/call":
      return await callTool(id, params["name"], params["arguments"], tools);
    case "ping":
      return reply(id, {});
    default:
      return failure(id, -32601, `Unknown method "${method}". This server implements initialize, tools/list, tools/call and ping.`);
  }
}

export async function serveMcp(): Promise<void> {
  guardStdout();
  const tools = createTools(core);
  const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
  const send = (message: RpcMessage | null): void => {
    const line = encode(message);
    if (line !== null) process.stdout.write(line);
  };
  try {
    for await (const line of input) {
      if (!line.trim()) continue;
      let parsed: unknown;
      try {
        parsed = JSON.parse(line);
      } catch (err) {
        send(failure(null, -32700, `Parse error: ${(err as Error).message}. Send one JSON-RPC object per line.`));
        continue;
      }
      try {
        send(await handleRpc(parsed, tools));
      } catch (err) {
        send(failure(null, -32603, `Internal error: ${(err as Error).message}`));
      }
    }
  } catch (err) {
    process.stderr.write(`[dustless mcp] stdin closed: ${(err as Error).message}\n`);
  } finally {
    input.close();
  }
}
