import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdir, rm, symlink } from "node:fs/promises";
import { dirname, join } from "node:path";
import { isRed, isRedReal } from "../../src/core/paths.ts";
import {
  cleanupAll,
  plant,
  sandbox,
  scanJson,
  userRules,
  type Sandbox,
} from "./harness.ts";

afterAll(cleanupAll);

describe("scan red-resolving path", () => {
  let box: Sandbox;
  const bytes = 4 * 1024 * 1024;

  const cachePath = (home: string): string => join(home, ".npm", "_cacache", "content-v2", "aa");

  beforeAll(async () => {
    box = await sandbox("scan-red-realpath");
  });

  afterAll(async () => {
    await box.dispose();
  });

  test("RED-RESOLVING: symlinked cache path is excluded and counted red", async () => {
    const home = box.home;
    const cp = cachePath(home);
    await mkdir(dirname(cp), { recursive: true });
    await plant(cp, bytes);
    await rm(cp, { recursive: true, force: true });
    const target = join(home, "Documents", "redtarget");
    await plant(target, bytes);
    await symlink(target, cp);
    await userRules(home, `- id: test.redreal\n  tier: green\n  desc: red real\n  paths: { all: ${JSON.stringify(cp)} }\n`);
    const report = scanJson((await box.run(["scan", "--json"])).stdout);
    expect(report.findings.some((f) => f.path === cp)).toBe(false);
    expect(report.reclaimable).toBe(0);
    expect(report.unscannableSummary.red).toBeGreaterThanOrEqual(1);
    const u = report.unscannable.find((r) => r.ruleId === "test.redreal");
    expect(u).toBeDefined();
    expect(u?.reason).toBe("red");
  });

  test("CONTROL: same path as real dir is present and counted", async () => {
    const home = box.home;
    const cp = cachePath(home);
    await rm(cp, { recursive: true, force: true });
    await plant(cp, bytes);
    await userRules(home, `- id: test.redrealctrl\n  tier: green\n  desc: red real ctrl\n  paths: { all: ${JSON.stringify(cp)} }\n`);
    const report = scanJson((await box.run(["scan", "--json"])).stdout);
    const hit = report.findings.find((f) => f.ruleId === "test.redrealctrl");
    expect(hit).toBeDefined();
    expect(hit?.path).toBe(cp);
    expect(hit?.bytes).toBe(bytes);
    expect(report.reclaimable).toBeGreaterThanOrEqual(bytes);
  });

  test("REALPATH: lexical path is clean but resolves red", async () => {
    const home = box.home;
    const cp = cachePath(home);
    await rm(cp, { recursive: true, force: true });
    const target = join(home, "Documents", "redtarget");
    await plant(target, bytes);
    await symlink(target, cp);
    expect(isRed(cp)).toBe(false);
    expect(isRedReal(cp)).toBe(true);
    await userRules(home, `- id: test.redreal2\n  tier: green\n  desc: red real2\n  paths: { all: ${JSON.stringify(cp)} }\n`);
    const report = scanJson((await box.run(["scan", "--json"])).stdout);
    expect(report.findings.some((f) => f.path === cp)).toBe(false);
    expect(report.unscannableSummary.red).toBeGreaterThanOrEqual(1);
  });
});