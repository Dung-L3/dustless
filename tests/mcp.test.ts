import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ApplyReport, Finding, Rule, ScanReport } from "../src/types.ts";
import { encode, guardStdout, handleRpc, PROTOCOL_VERSION, SERVER_INFO } from "../src/mcp/server.ts";
import { createTools, type Core, type Tool } from "../src/mcp/tools.ts";
import { AgentRefusal, assertAgentCanDelete, assertPathDeletable, assertWithinAgentCap, MAX_AGENT_DELETE_BYTES } from "../src/mcp/safety.ts";
import { isRed } from "../src/core/paths.ts";

const GIB = 1024 ** 3;
const CACHE = join(tmpdir(), "npm-cache");
const CACHE_YELLOW = join(tmpdir(), "npm-cache-yellow");
const PROTO = join(tmpdir(), "proto-cache");
const RULES: Rule[] = [
  { id: "npm.cacache", tier: "green", desc: "npm cache tarball", paths: { all: "~/.npm/_cacache" } },
  { id: "gradle.version_cache", tier: "green", desc: "gradle cache", paths: { all: "~/.gradle/caches/*" } },
  { id: "constructor", tier: "green", desc: "prototype-shaped id", paths: { all: "~/.cache/constructor" } },
];

function finding(over: Partial<Finding> = {}): Finding {
  return {
    ruleId: "npm.cacache", tier: "green", desc: "npm cache tarball", path: CACHE,
    bytes: 2 * GIB, mtime: 0, atime: 0, ageDays: 40, verified: true, blocked: false, note: "", ...over,
  };
}

function reportOf(findings: Finding[]): ScanReport {
  return {
    findings,
    totals: { green: { count: 0, bytes: 0 }, yellow: { count: 0, bytes: 0 }, red: { count: 0, bytes: 0 }, blocked: { count: 0, bytes: 0 } },
    reclaimable: 0, freeBefore: 100 * GIB, platform: "mac", scannedMs: 1,
    unscannable: [],
    unscannableSummary: { absent: 0, no_access: 0, not_supported: 0, error: 0, red: 0 },
  };
}

function fakeCore(over: Partial<Core> = {}): Core & { deleted: string[][] } {
  const deleted: string[][] = [];
  return {
    deleted,
    loadRules: async () => RULES,
    freeSpace: async () => 100 * GIB,
    scan: async () => reportOf([finding()]),
    apply: async (report, opts): Promise<ApplyReport> => {
      deleted.push(report.findings.map((f) => f.path));
      return {
        outcomes: report.findings.map((f) => ({
          ruleId: f.ruleId, tier: f.tier, path: f.path,
          status: opts?.tiers?.[f.ruleId] === "skip" ? "skipped" : "deleted",
          bytes: f.bytes, detail: "",
        })),
        freed: 0, freeBefore: 0, freeAfter: 0, elapsedMs: 1,
      };
    },
    ...over,
  };
}

type Reply = {
  jsonrpc: string; id: string | number | null; error?: { code: number; message: string };
  result?: { content?: Array<{ text: string }>; isError?: boolean } & Record<string, unknown>;
};

async function rpc(tools: Tool[], request: Record<string, unknown>): Promise<Reply> {
  const line = encode(await handleRpc(request, tools));
  if (line === null) throw new Error("expected a response, got none");
  return JSON.parse(line) as Reply;
}
function textOf(reply: Reply): string {
  return reply.result?.content?.[0]?.text ?? "";
}

function applyCall(tools: Tool[], id: number, args: Record<string, unknown>) {
  return rpc(tools, { jsonrpc: "2.0", id, method: "tools/call", params: { name: "apply", arguments: args } });
}

describe("jsonrpc", () => {
  test("initialize advertises a protocol version and server info", async () => {
    const reply = await rpc(createTools(fakeCore()), {
      jsonrpc: "2.0", id: 1, method: "initialize",
      params: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, clientInfo: { name: "test", version: "1" } },
    });
    expect(reply.jsonrpc).toBe("2.0");
    expect(reply.id).toBe(1);
    expect(reply.result?.protocolVersion).toBe(PROTOCOL_VERSION);
    expect(reply.result?.serverInfo).toEqual(SERVER_INFO);
    expect(reply.result?.capabilities).toHaveProperty("tools");
  });

  test("initialize falls back to the supported version for an unknown request", async () => {
    const reply = await rpc(createTools(fakeCore()), {
      jsonrpc: "2.0", id: 2, method: "initialize", params: { protocolVersion: "1999-01-01" },
    });
    expect(reply.result?.protocolVersion).toBe(PROTOCOL_VERSION);
  });

  test("unknown method returns an error object without throwing", async () => {
    const reply = await rpc(createTools(fakeCore()), { jsonrpc: "2.0", id: 3, method: "does/not/exist" });
    expect(reply.error?.code).toBe(-32601);
    expect(reply.result).toBeUndefined();
  });
  test("malformed payloads return -32600 and never throw", async () => {
    for (const bad of [null, [1, 2], "nope", { id: 4 }, { jsonrpc: "2.0", id: 5, method: "" }]) {
      const response = await handleRpc(bad, createTools(fakeCore()));
      expect(response).not.toBeNull();
      expect(response?.error?.code).toBe(-32600);
    }
  });
  test("notifications get no response and ping answers", async () => {
    const tools = createTools(fakeCore());
    expect(await handleRpc({ jsonrpc: "2.0", method: "notifications/initialized" }, tools)).toBeNull();
    expect(await rpc(tools, { jsonrpc: "2.0", id: 6, method: "ping" })).toMatchObject({ result: {} });
  });
});

describe("tools/list", () => {
  test("every tool has a usable name, description and inputSchema", async () => {
    const reply = await rpc(createTools(fakeCore()), { jsonrpc: "2.0", id: 7, method: "tools/list" });
    const tools = (reply.result?.tools ?? []) as Array<Record<string, unknown>>;
    expect(tools.map((tool) => tool["name"]).sort()).toEqual(["apply", "doctor", "free_space", "list_rules", "scan"]);
    for (const tool of tools) {
      expect((tool["description"] as string).length).toBeGreaterThan(80);
      const schema = tool["inputSchema"] as { type: string; required: unknown; properties: Record<string, Record<string, unknown>> };
      expect(schema.type).toBe("object");
      expect(Array.isArray(schema.required)).toBe(true);
      for (const [name, property] of Object.entries(schema.properties)) {
        expect(property["type"]).toBeDefined();
        expect(typeof property["description"]).toBe("string");
        expect(Object.keys(property).length).toBeGreaterThan(1);
        expect(name).not.toBe("");
      }
    }
  });
});

describe("scan options", () => {
  test("omitted roots stay undefined so the engine does not filter everything out", async () => {
    const seen: unknown[] = [];
    const core = fakeCore({
      scan: async (opts) => {
        seen.push(opts);
        return reportOf([finding()]);
      },
    });
    const tools = createTools(core);
    await rpc(tools, { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "scan", arguments: {} } });
    expect(seen[0]).toEqual({ roots: undefined, minBytes: 0 });
    await rpc(tools, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "scan", arguments: { roots: [], min_bytes: 5 } } });
    expect(seen[1]).toEqual({ roots: undefined, minBytes: 5 });
    await rpc(tools, { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "scan", arguments: { roots: ["/tmp/x"] } } });
    expect(seen[2]).toEqual({ roots: ["/tmp/x"], minBytes: 0 });
  });
  test("rule_id filters findings and reports a miss instead of an empty success", async () => {
    const tools = createTools(fakeCore());
    const hit = await rpc(tools, {
      jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "scan", arguments: { rule_id: "npm.cacache" } },
    });
    expect(hit.result?.isError).toBeFalsy();
    expect(textOf(hit)).toContain("npm.cacache");
    const miss = await rpc(tools, {
      jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "scan", arguments: { rule_id: "nope" } },
    });
    expect(miss.result?.isError).toBe(true);
    expect(textOf(miss)).toContain("list_rules");
  });
});

describe("apply safety", () => {
  test("blocked findings are counted as blocked, not reclaimable", async () => {
    const blockedYellow = finding({ ruleId: "gradle.version_cache", tier: "yellow", blocked: true, bytes: GIB, note: "in use" });
    const blockedGreen = finding({ ruleId: "gradle.version_cache", tier: "green", blocked: true, bytes: GIB / 2, note: "in use" });
    const tools = createTools(fakeCore({ scan: async () => reportOf([finding(), blockedYellow, blockedGreen]) }));
    const reply = await rpc(tools, {
      jsonrpc: "2.0", id: 99, method: "tools/call", params: { name: "scan", arguments: {} },
    });
    const structured = reply.result?.structuredContent as Record<string, unknown> | undefined;
    expect(structured?.["totals"]).toMatchObject({
      green: { count: 1, bytes: 2 * GIB },
      yellow: { count: 0, bytes: 0 },
      blocked: { count: 2, bytes: 1.5 * GIB },
    });
    expect(structured?.["reclaimable"]).toBe(2 * GIB);
  });

  test("apply without confirm deletes nothing and refuses clearly", async () => {
    const core = fakeCore();
    const reply = await applyCall(createTools(core), 8, { rule_ids: ["npm.cacache"] });
    expect(reply.result?.isError).toBe(true);
    expect(core.deleted).toEqual([]);
    expect(textOf(reply)).toContain("REFUSED");
    expect(textOf(reply)).toContain("confirm is not exactly true");
  });

  test("apply with confirm:true reaches the engine", async () => {
    const core = fakeCore();
    const reply = await applyCall(createTools(core), 9, { rule_ids: ["npm.cacache"], confirm: true });
    expect(reply.result?.isError).toBeFalsy();
    expect(core.deleted).toEqual([[CACHE]]);
  });

  test("an unknown rule id refuses the whole batch by name", async () => {
    const core = fakeCore();
    const reply = await applyCall(createTools(core), 10, { rule_ids: ["npm.cacache", "made.up"], confirm: true });
    expect(reply.result?.isError).toBe(true);
    expect(textOf(reply)).toContain("made.up");
    expect(core.deleted).toEqual([]);
  });

  test("a red path is refused even with confirm and allow_large", async () => {
    const core = fakeCore({ scan: async () => reportOf([finding({ ruleId: "gradle.version_cache", path: "/Users/me/Documents/gradle" })]) });
    const reply = await applyCall(createTools(core), 11, {
      rule_ids: ["gradle.version_cache"], confirm: true, allow_large: true,
    });
    expect(reply.result?.isError).toBe(true);
    expect(textOf(reply)).toContain("red blocklist");
    expect(core.deleted).toEqual([]);
  });

  test("a yellow finding is refused unless tier yellow is requested", async () => {
    const core = fakeCore({ scan: async () => reportOf([finding({ tier: "yellow", note: "project còn thay đổi chưa commit" })]) });
    const tools = createTools(core);
    const denied = await applyCall(tools, 12, { rule_ids: ["npm.cacache"], confirm: true });
    expect(denied.result?.isError).toBe(true);
    expect(textOf(denied)).toContain("permits only green");
    expect(core.deleted).toEqual([]);
    const allowed = await applyCall(tools, 13, { rule_ids: ["npm.cacache"], tier: "yellow", confirm: true });
    expect(allowed.result?.isError).toBeFalsy();
    expect(core.deleted).toEqual([[CACHE]]);
  });

  test("a rule that yields green and yellow findings is sent to the engine as yellow", async () => {
    const seen: unknown[] = [];
    const core = fakeCore({
      scan: async () => reportOf([finding({ tier: "yellow", path: CACHE_YELLOW }), finding({ path: CACHE })]),
      apply: async (report, opts) => {
        seen.push(opts?.tiers);
        return {
          outcomes: report.findings.map((f) => ({ ruleId: f.ruleId, tier: f.tier, path: f.path, status: "deleted", bytes: f.bytes, detail: "" })),
          freed: 0, freeBefore: 0, freeAfter: 0, elapsedMs: 1,
        };
      },
    });
    const reply = await applyCall(createTools(core), 15, { rule_ids: ["npm.cacache"], tier: "yellow", confirm: true });
    expect(reply.result?.isError).toBeFalsy();
    expect(seen).toEqual([{ "npm.cacache": "yellow" }]);
  });

  test("a rule id inherited from Object.prototype is sent with its own green tier", async () => {
    const seen: unknown[] = [];
    const core = fakeCore({
      scan: async () => reportOf([finding({ ruleId: "constructor", path: PROTO })]),
      apply: async (report, opts) => {
        seen.push(opts?.tiers);
        return {
          outcomes: report.findings.map((f) => ({ ruleId: f.ruleId, tier: f.tier, path: f.path, status: "deleted", bytes: f.bytes, detail: "" })),
          freed: 0, freeBefore: 0, freeAfter: 0, elapsedMs: 1,
        };
      },
    });
    const reply = await applyCall(createTools(core), 16, { rule_ids: ["constructor"], confirm: true });
    expect(reply.result?.isError).toBeFalsy();
    expect(seen).toEqual([{ constructor: "green" }]);
  });
});

describe("safety guards", () => {
  test("confirm gate throws unless confirm is exactly true", () => {
    expect(() => assertAgentCanDelete(["npm.cacache"], false)).toThrow(AgentRefusal);
    expect(() => assertAgentCanDelete(["npm.cacache"], false)).toThrow(/confirm is not exactly true/);
    expect(() => assertAgentCanDelete([], true)).toThrow(/at least one rule id/);
    expect(() => assertAgentCanDelete(["npm.cacache"], true)).not.toThrow();
  });

  test("the 50GB cap throws and only allow_large clears it", () => {
    const huge = [finding({ bytes: MAX_AGENT_DELETE_BYTES + 1 })];
    expect(() => assertWithinAgentCap(huge, false)).toThrow(/hard agent cap/);
    expect(assertWithinAgentCap(huge, true)).toBe(MAX_AGENT_DELETE_BYTES + 1);
    expect(assertWithinAgentCap([finding({ bytes: MAX_AGENT_DELETE_BYTES })], false)).toBe(MAX_AGENT_DELETE_BYTES);
  });

  test("over-cap apply is refused before the engine runs", async () => {
    const core = fakeCore({ scan: async () => reportOf([finding({ bytes: 60 * GIB })]) });
    const reply = await applyCall(createTools(core), 14, { rule_ids: ["npm.cacache"], confirm: true });
    expect(reply.result?.isError).toBe(true);
    expect(textOf(reply)).toContain("hard agent cap");
    expect(core.deleted).toEqual([]);
  });

  test("the red guard is re-exported and blocks protected paths", () => {
    expect(isRed("/Users/me/Library/Mail/V10")).toBe(true);
    expect(isRed("/Users/me/project/.git/objects")).toBe(true);
    expect(() => assertPathDeletable(finding({ path: "/Users/me/Pictures/x" }))).toThrow(/red blocklist/);
    expect(() => assertPathDeletable(finding({ path: CACHE }))).not.toThrow();
  });

  test("bad argument types give a correctable message, not a stack trace", async () => {
    const reply = await applyCall(createTools(fakeCore()), 15, { rule_ids: "npm.cacache", confirm: true });
    expect(reply.result?.isError).toBe(true);
    expect(textOf(reply)).toContain("rule_ids must be an array of non-empty strings");
    expect(textOf(reply)).not.toContain("\n    at ");
  });
});

describe("stdout purity", () => {
  const captured: string[] = [];
  const errors: string[] = [];
  const realOut = process.stdout.write.bind(process.stdout);
  const realErr = process.stderr.write.bind(process.stderr);
  const realConsole = { ...console };
  const emit = async (tools: Tool[], request: Record<string, unknown>) => {
    process.stdout.write(encode(await handleRpc(request, tools)) ?? "");
  };

  beforeAll(() => {
    process.stdout.write = ((chunk: string | Uint8Array) => (captured.push(String(chunk)), true)) as typeof process.stdout.write;
    process.stderr.write = ((chunk: string | Uint8Array) => (errors.push(String(chunk)), true)) as typeof process.stderr.write;
  });

  afterAll(() => {
    process.stdout.write = realOut;
    process.stderr.write = realErr;
    Object.assign(console, realConsole);
  });

  test("console noise is redirected to stderr, never stdout", async () => {
    captured.length = 0;
    errors.length = 0;
    guardStdout();
    for (const method of ["log", "info", "warn", "error"] as const) console[method](`stray ${method} line`);
    const tools = createTools(fakeCore());
    for (const name of ["doctor", "list_rules", "free_space"]) {
      await emit(tools, { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name } });
    }
    expect(captured.join("")).not.toContain("stray");
    expect(errors.join("")).toContain("stray log line");
    for (const line of captured) expect(JSON.parse(line).jsonrpc).toBe("2.0");
  });
  test("a real scan tool call emits only valid JSON-RPC on stdout", async () => {
    captured.length = 0;
    const scratch = await mkdtemp(join(tmpdir(), "dustless-mcp-"));
    try {
      const { scan } = await import("../src/core/scan.ts");
      const tools = createTools({ ...fakeCore(), scan });
      for (const method of ["initialize", "tools/list"]) await emit(tools, { jsonrpc: "2.0", id: 1, method });
      await emit(tools, { jsonrpc: "2.0", id: 19, method: "tools/call", params: { name: "scan", arguments: { roots: [scratch] } } });
      const lines = captured.join("").split("\n").filter(Boolean);
      expect(lines.length).toBe(3);
      for (const line of lines) expect(JSON.parse(line).jsonrpc).toBe("2.0");
      const scanned = (JSON.parse(lines[2] ?? "{}") as Reply).result;
      expect(scanned?.content?.[0]?.text).toContain("Dustless scan");
      expect((scanned?.structuredContent as { findings_shown: number }).findings_shown).toBe(0);
    } finally {
      await rm(scratch, { recursive: true, force: true });
    }
  }, 30000);
});
