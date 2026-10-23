import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { mkdtemp, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BINARY, MB, plant, VERSION } from "./harness.ts";

type RpcError = { code: number; message: string };

type Reply = {
  jsonrpc: string;
  id: number | string | null;
  error?: RpcError;
  result?: Record<string, unknown>;
};

type ToolResultContent = {
  content?: Array<{ text: string }>;
  structuredContent?: Record<string, unknown>;
  isError?: boolean;
};

type Client = {
  rpc: (method: string, params?: unknown) => Promise<Reply>;
  sendRaw: (line: string) => Promise<Reply>;
  badLines: () => string[];
  stderr: () => string;
  dispose: () => Promise<void>;
};

const RPC_TIMEOUT_MS = 15_000;

const pathExists = async (path: string): Promise<boolean> => await stat(path).then(() => true, () => false);

function startServer(home: string): Client {
  const child = spawn(BINARY, ["mcp"], {
    env: {
      PATH: process.platform === "win32" ? process.env["PATH"] ?? "" : "/usr/bin:/bin:/usr/sbin:/sbin",
      HOME: home,
      USERPROFILE: home,
      NO_COLOR: "1",
      TMPDIR: tmpdir(),
    },
    cwd: "/",
    stdio: ["pipe", "pipe", "pipe"],
  });
  const stdin = child.stdin;
  let raw = "";
  const bad: string[] = [];
  let waitReplies: ((reply: Reply) => void) | null = null;
  const pending = new Map<number, { resolve: (reply: Reply) => void; timer: NodeJS.Timeout }>();

  const deliver = (reply: Reply): void => {
    if (reply.id !== null && reply.id !== undefined && pending.has(Number(reply.id))) {
      const waiter = pending.get(Number(reply.id));
      pending.delete(Number(reply.id));
      clearTimeout(waiter?.timer);
      waiter?.resolve(reply);
      return;
    }
    if (waitReplies) {
      const settle = waitReplies;
      waitReplies = null;
      settle(reply);
      return;
    }
    bad.push(JSON.stringify(reply));
  };

  child.stdout?.on("data", (chunk: Buffer) => {
    raw += chunk.toString();
    for (;;) {
      const at = raw.indexOf("\n");
      if (at < 0) break;
      const line = raw.slice(0, at);
      raw = raw.slice(at + 1);
      if (!line.trim()) continue;
      try {
        deliver(JSON.parse(line) as Reply);
      } catch {
        bad.push(line);
      }
    }
  });

  let stderrText = "";
  child.stderr?.on("data", (chunk: Buffer) => (stderrText += chunk.toString()));

  let idCounter = 0;
  const rpc = (method: string, params: unknown = {}, ms = RPC_TIMEOUT_MS): Promise<Reply> =>
    new Promise((resolve, reject) => {
      const id = ++idCounter;
      const timer = setTimeout(() => {
        pending.delete(id);
        child.kill("SIGKILL");
        reject(new Error(`no response to ${method} (id ${id}) within ${ms}ms`));
      }, ms);
      pending.set(id, { resolve: (reply) => { clearTimeout(timer); resolve(reply); }, timer });
      stdin?.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    });

  const sendRaw = (line: string, ms = RPC_TIMEOUT_MS): Promise<Reply> =>
    new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        child.kill("SIGKILL");
        reject(new Error(`no response to raw input within ${ms}ms: ${line}`));
      }, ms);
      waitReplies = (reply) => { clearTimeout(timer); resolve(reply); };
      stdin?.write(`${line}\n`);
    });

  const dispose = (): Promise<void> =>
    new Promise<void>((done) => {
      if (child.exitCode !== null) return done();
      child.once("close", () => done());
      stdin?.end();
      setTimeout(() => {
        if (child.exitCode === null) child.kill("SIGKILL");
      }, 5_000).unref();
    });

  return { rpc, sendRaw, badLines: () => bad, stderr: () => stderrText, dispose };
}

function expectNotError(result: ToolResultContent): void {
  expect(result.isError).toBeFalsy();
}

describe("mcp server over stdio", () => {
  let home: string;
  let client: Client;
  const cacheDir = (): string => join(home, ".npm", "_cacache");
  const planted = 2 * MB;

  beforeAll(async () => {
    home = await mkdtemp(join(tmpdir(), "dustless-e2e-mcp-"));
    await plant(cacheDir(), planted, 2);
    client = startServer(home);
  });

  afterAll(async () => {
    await client.dispose();
  });

  test(
    "initialize returns serverInfo, tools capability and confirm-first instructions",
    async () => {
      const reply = await client.rpc("initialize", {
        protocolVersion: "2025-06-18",
        capabilities: {},
        clientInfo: { name: "e2e", version: "0" },
      });
      expect(reply.error).toBeUndefined();
      expect(reply.result?.protocolVersion).toBe("2025-06-18");
      expect(reply.result?.capabilities).toEqual({ tools: { listChanged: false } });
      expect(reply.result?.serverInfo).toEqual({ name: "dustless", version: VERSION });
      const instructions = reply.result?.instructions as string;
      expect(instructions).toContain("confirm: true");
      expect(instructions).toContain("Never pass a path as a rule id");
      const alive = await client.rpc("ping");
      expect(alive.result).toEqual({});
    },
    30_000,
  );

  test("tools/list returns exactly the five documented tools", async () => {
    const reply = await client.rpc("tools/list");
    const tools = (reply.result?.tools as Array<Record<string, unknown>>) ?? [];
    expect(tools.map((tool) => tool["name"]).sort()).toEqual([
      "apply",
      "doctor",
      "free_space",
      "list_rules",
      "scan",
    ]);
    const apply = tools.find((tool) => tool["name"] === "apply");
    const applySchema = apply?.["inputSchema"] as Record<string, unknown> | undefined;
    expect(applySchema?.["required"]).toEqual(["rule_ids"]);
    const applyProps = (applySchema?.["properties"] as Record<string, unknown>) ?? {};
    expect(Object.keys(applyProps).sort()).toEqual(["allow_large", "confirm", "rule_ids", "tier"]);
    for (const tool of tools) {
      expect(String(tool["description"]).length).toBeGreaterThan(80);
      expect((tool["inputSchema"] as Record<string, unknown>)["type"]).toBe("object");
    }
  });

  test("scan returns the contract-shaped report with exact planted bytes and zero pre-selection", async () => {
    const reply = await client.rpc("tools/call", { name: "scan", arguments: {} });
    expect(reply.error).toBeUndefined();
    const result = reply.result as ToolResultContent;
    expectNotError(result);
    const structured = result.structuredContent as {
      scanned_ms: number;
      findings_total: number;
      findings_shown: number;
      free_before: number;
      reclaimable: number;
      totals: Record<string, { count: number; bytes: number }>;
      rules: Array<{ rule_id: string; tier: string; count: number; bytes: number; blocked: boolean; note: string; paths: string[]; paths_hidden: number }>;
    };
    expect(Object.keys(structured).sort()).toEqual([
      "findings_shown",
      "findings_total",
      "free_before",
      "reclaimable",
      "rules",
      "scanned_ms",
      "totals",
    ]);
    expect(structured.findings_total).toBe(1);
    expect(structured.findings_shown).toBe(1);
    expect(structured.free_before).toBeGreaterThan(0);
    expect(structured.reclaimable).toBe(planted);
    expect(structured.totals["green"]).toEqual({ count: 1, bytes: planted });
    expect(structured.totals["blocked"]).toEqual({ count: 0, bytes: 0 });
    expect(structured.rules).toHaveLength(1);
    const rule = structured.rules[0] ?? { rule_id: "", tier: "", count: 0, bytes: 0, blocked: false, note: [], paths: [""], paths_hidden: 0 };
    expect(rule.rule_id).toBe("npm.cacache");
    expect(rule.tier).toBe("green");
    expect(rule.count).toBe(1);
    expect(rule.bytes).toBe(planted);
    expect(rule.blocked).toBe(false);
    expect(rule.paths).toEqual([cacheDir()]);
    expect(result.content?.[0]?.text).toContain("Dustless scan");
    expect(result.content?.[0]?.text).toContain("Nothing was deleted");
  });

  test("apply with confirm absent or false is refused and deletes nothing", async () => {
    const absent = (await client.rpc("tools/call", { name: "apply", arguments: { rule_ids: ["npm.cacache"] } })).result as ToolResultContent;
    expect(absent.isError).toBe(true);
    expect(String(absent.content?.[0]?.text)).toContain("REFUSED");
    expect(String(absent.content?.[0]?.text)).toContain("confirm is not exactly true");
    expect(absent.structuredContent?.["confirm"]).toBe(false);
    expect(absent.structuredContent?.["would_delete"]).toHaveLength(1);
    const forced = (await client.rpc("tools/call", { name: "apply", arguments: { rule_ids: ["npm.cacache"], confirm: false } })).result as ToolResultContent;
    expect(forced.isError).toBe(true);
    expect(String(forced.content?.[0]?.text)).toContain("REFUSED");
    expect(await pathExists(cacheDir())).toBe(true);
  });

  test("apply naming an unknown rule id or a red path is refused with nothing deleted", async () => {
    const unknown = (await client.rpc("tools/call", {
      name: "apply",
      arguments: { rule_ids: ["npm.cacache", "made.up"], confirm: true },
    })).result as ToolResultContent;
    expect(unknown.isError).toBe(true);
    expect(String(unknown.content?.[0]?.text)).toContain("Unknown rule id(s)");
    expect(String(unknown.content?.[0]?.text)).toContain("made.up");
    const red = (await client.rpc("tools/call", {
      name: "apply",
      arguments: { rule_ids: ["~/Library/Mail"], confirm: true, allow_large: true },
    })).result as ToolResultContent;
    expect(red.isError).toBe(true);
    expect(String(red.content?.[0]?.text)).toContain("Unknown rule id(s)");
    expect(String(red.content?.[0]?.text)).toContain("~/Library/Mail");
    expect(await pathExists(cacheDir())).toBe(true);
  });

  test(
    "apply with confirm true deletes the planted cache and reports a measured freed delta",
    async () => {
      const reply = await client.rpc("tools/call", {
        name: "apply",
        arguments: { rule_ids: ["npm.cacache"], confirm: true },
      });
      expect(reply.error).toBeUndefined();
      const result = reply.result as ToolResultContent;
      expectNotError(result);
      const structured = result.structuredContent as {
        freed: number;
        free_before: number;
        free_after: number;
        elapsed_ms: number;
        deleted: Array<{ rule_id: string; path: string; bytes: number }>;
        not_deleted: unknown[];
      };
      expect(objKeys(structured)).toEqual(["deleted", "elapsed_ms", "free_after", "free_before", "freed", "not_deleted"]);
      expect(structured.deleted).toEqual([{ rule_id: "npm.cacache", path: cacheDir(), bytes: planted }]);
      expect(structured.not_deleted).toEqual([]);
      expect(structured.free_before).toBeGreaterThan(0);
      expect(structured.free_after).toBeGreaterThan(0);
      expect(structured.elapsed_ms).toBeGreaterThan(0);
      expect(structured.freed).toBe(Math.max(0, structured.free_after - structured.free_before));
      expect(String(result.content?.[0]?.text)).toContain("Volume free space rose by");
      expect(await pathExists(cacheDir())).toBeFalse();
    },
    30_000,
  );

  test("malformed JSON-RPC input gets error responses and the server keeps serving", async () => {
    const parseError = await client.sendRaw("this is not json");
    expect(parseError.id).toBeNull();
    expect(parseError.error?.code).toBe(-32700);
    expect(parseError.error?.message).toContain("Parse error");
    const batch = await client.sendRaw('["not","a","single","object"]');
    expect(batch.id).toBeNull();
    expect(batch.error?.code).toBe(-32600);
    const missingJsonrpc = await client.sendRaw('{"method":"tools/list","id":4096}');
    expect(missingJsonrpc.id).toBe(4096);
    expect(missingJsonrpc.error?.code).toBe(-32600);
    const alive = await client.rpc("ping");
    expect(alive.error).toBeUndefined();
    expect(alive.result).toEqual({});
    expect(client.badLines()).toEqual([]);
    expect(client.stderr()).toBe("");
  });
});

function objKeys(value: Record<string, unknown>): string[] {
  return Object.keys(value).sort();
}
