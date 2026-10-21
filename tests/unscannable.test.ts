import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile, chmod } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { UnscannableReason } from "../src/types.ts";
import { scan } from "../src/core/scan.ts";
import { sandbox as e2eSandbox, scanJson, userRules } from "./e2e/harness.ts";

const sandbox = await mkdtemp(join(tmpdir(), "dustless-unscannable-"));
const priorConfigHome = process.env["XDG_CONFIG_HOME"];
process.env["XDG_CONFIG_HOME"] = join(sandbox, "config");

const writeRules = async (body: string): Promise<string> => {
  const { userRulesPath } = await import("../src/core/rules.ts");
  await mkdir(join(sandbox, "config", "dustless"), { recursive: true });
  await writeFile(userRulesPath(), body);
  return userRulesPath();
};

afterAll(async () => {
  if (priorConfigHome === undefined) delete process.env["XDG_CONFIG_HOME"];
  else process.env["XDG_CONFIG_HOME"] = priorConfigHome;
  spawnSync("chmod", ["-R", "u+rwX", sandbox], { stdio: "ignore" });
  await rm(sandbox, { recursive: true, force: true });
});

describe("unscannable tracking", () => {
  test("absent path yields reason absent", async () => {
    const missing = join(sandbox, "missing-cache");
    await writeRules(
      `- id: test.absent\n  tier: green\n  desc: absent cache\n  paths: { all: ${JSON.stringify(missing)} }\n`,
    );
    const report = await scan({ roots: [sandbox] });
    const u = report.unscannable.find((r) => r.ruleId === "test.absent");
    expect(u).toBeDefined();
    expect(u?.reason).toBe("absent");
    expect(u?.pathPatterns).toContain(missing);
    expect(report.unscannableSummary.absent).toBeGreaterThanOrEqual(1);
  });

  test.skipIf(process.platform === "win32")("unreadable path yields reason no_access", async () => {
    const unreadable = join(sandbox, "unreadable-cache");
    await mkdir(unreadable, { recursive: true });
    await writeFile(join(unreadable, "data.bin"), Buffer.alloc(1024, 7));
    await chmod(unreadable, 0o000);
    await writeRules(
      `- id: test.noaccess\n  tier: green\n  desc: no access cache\n  paths: { all: ${JSON.stringify(unreadable)} }\n`,
    );
    const report = await scan({ roots: [sandbox] });
    const u = report.unscannable.find((r) => r.ruleId === "test.noaccess");
    expect(u).toBeDefined();
    expect(u?.reason).toBe("no_access");
    expect(u?.pathPatterns).toContain(unreadable);
    expect(report.unscannableSummary.no_access).toBeGreaterThanOrEqual(1);
    expect(report.reclaimable).toBe(0);
    await chmod(unreadable, 0o700);
  });

  test("rule with no platform path yields not_supported", async () => {
    const other = process.platform === "win32" ? "mac" : "win";
    await writeRules(
      `- id: test.nosupport\n  tier: green\n  desc: no support cache\n  paths: { ${other}: "~/.never" }\n`,
    );
    const report = await scan({ roots: [sandbox] });
    const u = report.unscannable.find((r) => r.ruleId === "test.nosupport");
    expect(u).toBeDefined();
    expect(u?.reason).toBe("not_supported");
    expect(report.unscannableSummary.not_supported).toBeGreaterThanOrEqual(1);
  });

  test("a rule that reaches $HOME yields reason protected", async () => {
    await writeRules(`- id: test.protected\n  tier: green\n  desc: home scope\n  paths: { all: "~" }\n`);
    const report = await scan({ roots: [sandbox] });
    const u = report.unscannable.find((r) => r.ruleId === "test.protected");
    expect(u).toBeDefined();
    expect(u?.reason).toBe("protected");
    expect(u?.pathPatterns).toContain("~");
    expect(report.unscannableSummary.protected).toBeGreaterThanOrEqual(1);
    expect(report.findings.some((f) => f.ruleId === "test.protected")).toBe(false);
    expect(report.reclaimable).toBe(0);
  });

  test("a rule that reaches the filesystem root yields reason protected", async () => {
    await writeRules(`- id: test.root\n  tier: green\n  desc: root scope\n  paths: { all: "/" }\n`);
    const report = await scan({ roots: [sandbox] });
    const u = report.unscannable.find((r) => r.ruleId === "test.root");
    expect(u).toBeDefined();
    expect(u?.reason).toBe("protected");
    expect(report.findings.some((f) => f.ruleId === "test.root")).toBe(false);
    expect(report.reclaimable).toBe(0);
  });

  test("rule with scannable path but zero findings is not unscannable", async () => {
    const empty = join(sandbox, "empty-cache");
    await mkdir(empty, { recursive: true });
    await writeRules(
      `- id: test.empty\n  tier: green\n  desc: empty cache\n  paths: { all: ${JSON.stringify(empty)} }\n`,
    );
    const report = await scan({ roots: [sandbox] });
    const u = report.unscannable.find((r) => r.ruleId === "test.empty");
    expect(u).toBeUndefined();
  });

  test("unscannableSummary always has all four keys", async () => {
    const report = await scan({ roots: [sandbox] });
    const keys: UnscannableReason[] = ["absent", "no_access", "not_supported", "error"];
    for (const key of keys) {
      expect(report.unscannableSummary[key]).toBeDefined();
      expect(typeof report.unscannableSummary[key]).toBe("number");
    }
    expect(typeof report.unscannableSummary.protected).toBe("number");
  });

  test("fresh scan pre-selects zero items (initialSelection empty)", async () => {
    const report = await scan({ roots: [sandbox] });
    expect(report.findings).toEqual([]);
    expect(report.reclaimable).toBe(0);
    expect(report.totals.green.count).toBe(0);
    expect(report.totals.green.bytes).toBe(0);
  });
});

describe("unscannable e2e", () => {
  let box: Awaited<ReturnType<typeof e2eSandbox>>;

  beforeAll(async () => {
    box = await e2eSandbox("unscannable-e2e");
  });

  afterAll(async () => {
    await box.dispose();
  });

  test("absent rule path appears in unscannable with reason absent", async () => {
    await userRules(box.home, `- id: e2e.absent\n  tier: green\n  desc: e2e absent\n  paths: { all: "~/nonexistent" }\n`);
    const report = scanJson((await box.run(["scan", "--json"])).stdout);
    const u = report.unscannable.find((r) => r.ruleId === "e2e.absent");
    expect(u).toBeDefined();
    expect(u?.reason).toBe("absent");
    expect(report.reclaimable).toBe(0);
  });

  test.skipIf(process.platform === "win32")("unreadable rule path appears in unscannable with reason no_access", async () => {
    const unreadable = join(box.home, ".unreadable-cache");
    await mkdir(unreadable, { recursive: true });
    await writeFile(join(unreadable, "data.bin"), Buffer.alloc(1024, 7));
    await chmod(unreadable, 0o000);
    await userRules(box.home, `- id: e2e.noaccess\n  tier: green\n  desc: e2e no access\n  paths: { all: "~/.unreadable-cache" }\n`);
    const report = scanJson((await box.run(["scan", "--json"])).stdout);
    const u = report.unscannable.find((r) => r.ruleId === "e2e.noaccess");
    expect(u).toBeDefined();
    expect(u?.reason).toBe("no_access");
    expect(report.reclaimable).toBe(0);
    await chmod(unreadable, 0o700);
  });

  test("json error contract unchanged: unknown flag returns error object on stdout", async () => {
    const run = await box.run(["scan", "--json", "--invalid-flag"]);
    expect(run.code).toBe(1);
    expect(run.stderr).toBe("");
    const parsed = JSON.parse(run.stdout);
    expect(parsed).toHaveProperty("error");
    expect(typeof parsed.error).toBe("string");
    expect(parsed.error).toContain("unknown flag");
  });
});