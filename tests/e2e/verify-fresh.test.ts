import { afterAll, describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { mkdir, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BINARY, cleanupAll, sandbox, userRules, type Sandbox } from "./harness.ts";

const VERSION = "9.9.9";

type Reply = { id?: number; result?: Record<string, unknown>; error?: { message: string } };

type ToolCall = { structuredContent?: Record<string, unknown>; isError?: boolean; content?: Array<{ text: string }> };

const exists = async (path: string): Promise<boolean> =>
  await stat(path).then(() => true, () => false);

function startServer(home: string): { call: (name: string, args: Record<string, unknown>) => Promise<ToolCall>; stop: () => Promise<void> } {
  const child = spawn(BINARY, ["mcp"], {
    env: {
      PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
      HOME: home,
      USERPROFILE: home,
      NO_COLOR: "1",
      TMPDIR: tmpdir(),
    },
    cwd: "/",
    stdio: ["pipe", "pipe", "pipe"],
  });
  let raw = "";
  const pending = new Map<number, (reply: Reply) => void>();
  child.stdout?.on("data", (chunk: Buffer) => {
    raw += chunk.toString();
    for (;;) {
      const at = raw.indexOf("\n");
      if (at < 0) break;
      const line = raw.slice(0, at);
      raw = raw.slice(at + 1);
      if (!line.trim()) continue;
      let parsed: Reply;
      try {
        parsed = JSON.parse(line) as Reply;
      } catch {
        continue;
      }
      if (parsed.id === undefined) continue;
      const waiter = pending.get(Number(parsed.id));
      if (!waiter) continue;
      pending.delete(Number(parsed.id));
      waiter(parsed);
    }
  });
  let counter = 0;
  const rpc = (method: string, params: unknown): Promise<Reply> =>
    new Promise((resolve, reject) => {
      const id = ++counter;
      const timer = setTimeout(() => {
        pending.delete(id);
        child.kill("SIGKILL");
        reject(new Error(`no reply to ${method} within 30s`));
      }, 30_000);
      pending.set(id, (reply) => {
        clearTimeout(timer);
        resolve(reply);
      });
      child.stdin?.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    });
  const call = async (name: string, args: Record<string, unknown>): Promise<ToolCall> => {
    const reply = await rpc("tools/call", { name, arguments: args });
    const result = reply.result as { content?: Array<{ text: string; type: string }>; structuredContent?: Record<string, unknown>; isError?: boolean } | undefined;
    return {
      content: result?.content?.map((entry) => ({ text: entry.text })),
      structuredContent: result?.structuredContent,
      isError: result?.isError,
    };
  };
  const stop = async (): Promise<void> => {
    if (child.exitCode !== null) return;
    child.stdin?.end();
    await new Promise<void>((done) => {
      child.once("close", () => done());
      setTimeout(() => {
        if (child.exitCode === null) child.kill("SIGKILL");
      }, 5_000).unref();
    });
  };
  return { call, stop };
}

async function scene(label: string): Promise<{ box: Sandbox; cache: string; server: ReturnType<typeof startServer> }> {
  const box = await sandbox(label);
  const cache = join(box.home, "gradle-cache", VERSION);
  await mkdir(cache, { recursive: true });
  await writeFile(join(cache, "blob.bin"), Buffer.alloc(4096, 7));
  await userRules(
    box.home,
    `- id: test.gradle\n  tier: green\n  desc: gradle version cache\n  paths: { all: ${JSON.stringify(cache)} }\n  requireVerify: gradle_version_unused\n  recoveryLabel: download\n`,
  );
  return { box, cache, server: startServer(box.home) };
}

async function projectUsing(box: Sandbox): Promise<void> {
  const root = join(box.home, "proj");
  await mkdir(join(root, "gradle", "wrapper"), { recursive: true });
  await writeFile(join(root, "package.json"), "{}\n");
  await writeFile(
    join(root, "gradle", "wrapper", "gradle-wrapper.properties"),
    `distributionUrl=https\\://services.gradle.org/distributions/gradle-${VERSION}-bin.zip\n`,
  );
}

afterAll(cleanupAll);

describe("the delete path verifies the rule again instead of trusting the scan", () => {
  test("a project that starts using the cached version between the scan and the delete stops the delete", async () => {
    const { box, cache, server } = await scene("verify-fresh");
    try {
      const scanned = await server.call("scan", {});
      expect(scanned.structuredContent?.["findings_total"]).toBe(1);

      await projectUsing(box);

      const applied = await server.call("apply", { rule_ids: ["test.gradle"], tier: "green", confirm: true });
      const notDeleted = (applied.structuredContent?.["not_deleted"] ?? []) as Array<{ path: string; detail: string }>;
      expect(notDeleted).toHaveLength(1);
      expect(notDeleted[0]?.detail).toContain("gradle_used");
      expect(await exists(cache)).toBe(true);
    } finally {
      await server.stop();
      await box.dispose();
    }
  });

  test("a cache nobody uses is still deleted", async () => {
    const { box, cache, server } = await scene("verify-fresh-clean");
    try {
      const applied = await server.call("apply", { rule_ids: ["test.gradle"], tier: "green", confirm: true });
      const deleted = (applied.structuredContent?.["deleted"] ?? []) as Array<{ path: string }>;
      expect(deleted).toHaveLength(1);
      expect(await exists(cache)).toBe(false);
    } finally {
      await server.stop();
      await box.dispose();
    }
  });
});
