import { afterAll, beforeAll, describe, expect, mock, test } from "bun:test";
import { mkdir, mkdtemp, rm, stat, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import type { Finding, ScanReport } from "../src/types.ts";
import { HOME, isRed } from "../src/core/paths.ts";
import { loadRules, userRulesPath } from "../src/core/rules.ts";
import { freeSpace } from "../src/core/space.ts";
import { scan } from "../src/core/scan.ts";
import { apply } from "../src/core/apply.ts";

const sandbox = await mkdtemp(join(tmpdir(), "dustless-"));
const originalXdg = process.env["XDG_CONFIG_HOME"];
process.env["XDG_CONFIG_HOME"] = join(sandbox, "config");

const writeRules = async (body: string): Promise<string> => {
  await mkdir(dirname(userRulesPath()), { recursive: true });
  await writeFile(userRulesPath(), body);
  return userRulesPath();
};

const exists = async (path: string): Promise<boolean> => await stat(path).then(() => true, () => false);

const finding = (path: string, bytes = 1024): Finding => ({
  ruleId: "test.cache",
  tier: "green",
  desc: "x",
  path,
  bytes,
  mtime: 0,
  atime: 0,
  ageDays: 999,
  verified: true,
  blocked: false,
  note: "",
});

const report = (findings: Finding[], freeBefore = 0): ScanReport => ({
  findings,
  totals: { green: { count: 0, bytes: 0 }, yellow: { count: 0, bytes: 0 }, red: { count: 0, bytes: 0 }, blocked: { count: 0, bytes: 0 } },
  reclaimable: 0,
  freeBefore,
  platform: "mac",
  scannedMs: 0,
});

afterAll(async () => {
  if (originalXdg === undefined) delete process.env["XDG_CONFIG_HOME"];
  else process.env["XDG_CONFIG_HOME"] = originalXdg;
  await rm(sandbox, { recursive: true, force: true });
});

describe("rules", () => {
  test("loads bundled defaults when no user file exists", async () => {
    const rules = await loadRules();
    expect(rules.length).toBeGreaterThan(20);
    expect(rules.every((rule) => rule.tier === "green" || rule.tier === "yellow")).toBe(true);
    expect(rules.map((rule) => rule.id)).toContain("gradle.version_cache");
  });

  test("user file overrides a bundled rule by id", async () => {
    const file = await writeRules(
      `- id: bun.cache\n  tier: yellow\n  desc: bản riêng\n  paths: { all: "~/.bun/install/cache" }\n`,
    );
    const rules = await loadRules(file);
    expect(rules.filter((rule) => rule.id === "bun.cache")).toEqual([
      { id: "bun.cache", tier: "yellow", desc: "bản riêng", paths: { all: "~/.bun/install/cache" } },
    ]);
    expect(rules.map((rule) => rule.id)).toContain("npm.cacache");
  });

  test("a rule keeps its id when a platform lists several paths", async () => {
    const rules = await loadRules();
    const homebrew = rules.filter((rule) => rule.id.startsWith("homebrew.cache"));
    expect(homebrew).toHaveLength(1);
    const macPaths = homebrew[0]?.paths.mac;
    expect(Array.isArray(macPaths)).toBe(true);
    expect(macPaths).toHaveLength(2);
    expect(rules.some((rule) => /\.\d$/.test(rule.id))).toBe(false);
  });

  test("rejects an unknown tier and names the offending id", async () => {
    const file = await writeRules(`- id: my.rule\n  tier: red\n  desc: x\n  paths: { all: "~/x" }\n`);
    expect(loadRules(file)).rejects.toThrow(/my\.rule.*green\|yellow/);
  });

  test("rejects missing fields and names the offending id", async () => {
    const file = await writeRules(
      `- id: no.paths\n  tier: green\n  desc: x\n- tier: green\n  desc: y\n  paths: { all: "~/x" }\n`,
    );
    expect(loadRules(file)).rejects.toThrow(/no\.paths: thiếu paths[\s\S]*<thiếu id>: thiếu id/);
  });

  test("rejects unknown platform keys and empty path lists", async () => {
    const bad = await writeRules(`- id: k\n  tier: green\n  desc: x\n  paths: { solaris: "~/x" }\n`);
    expect(loadRules(bad)).rejects.toThrow(/k: paths\.solaris/);
    const empty = await writeRules(`- id: e\n  tier: green\n  desc: x\n  paths: { all: [] }\n`);
    expect(loadRules(empty)).rejects.toThrow(/e: paths\.all/);
  });

  test("rejects a missing explicit file", async () => {
    expect(loadRules(join(sandbox, "nope.yaml"))).rejects.toThrow(/không tìm thấy file rules/);
  });

  test("user rules path honours XDG_CONFIG_HOME", () => {
    expect(userRulesPath()).toBe(join(sandbox, "config", "dustless", "rules.yaml"));
  });
});

describe("red list", () => {
  test("blocks protected paths", () => {
    for (const path of [
      "/Users/me/Library/Keychains",
      HOME + "/Library/Caches/nothing.db-wal",
      HOME + "/proj/.git/objects",
      HOME + "/Documents/notes",
      HOME + "/Desktop/x",
      HOME + "/Library/Mail/V9",
    ]) {
      expect(isRed(path)).toBe(true);
    }
  });

  test("allows ordinary caches", () => {
    for (const path of [HOME + "/.gradle/caches/8.12", HOME + "/.npm/_cacache", HOME + "/Library/Caches/BraveSoftware"]) {
      expect(isRed(path)).toBe(false);
    }
  });
});

describe("space", () => {
  test("returns a plausible free size", async () => {
    expect(await freeSpace(HOME)).toBeGreaterThan(0);
  });

  test("falls back to df when statfs returns garbage", async () => {
    const honest = await import("node:fs/promises");
    const viaStatfs = (await honest.statfs(HOME)).bsize * (await honest.statfs(HOME)).bavail;
    mock.module("node:fs/promises", () => ({
      ...honest,
      statfs: async () => ({ bsize: 0, blocks: -1, bfree: -1, bavail: -1, files: -1, ffree: -1423792296 }),
    }));
    const garbage = await import("../src/core/space.ts");
    const free = await garbage.freeSpace(HOME);
    mock.restore();
    expect(free).toBeGreaterThan(0);
    expect(Math.abs(free - viaStatfs) / free).toBeLessThan(0.05);
  });
});

describe("scan", () => {
  const fixture = join(sandbox, "fixture");

  beforeAll(async () => {
    await mkdir(join(fixture, "cache", "fresh"), { recursive: true });
    await mkdir(join(fixture, "red", "Keychains"), { recursive: true });
    await mkdir(join(fixture, "tiny"), { recursive: true });
    await mkdir(join(fixture, "aged"), { recursive: true });
    await writeFile(join(fixture, "cache", "big.bin"), Buffer.alloc(4096, 7));
    await writeFile(join(fixture, "cache", "small.bin"), Buffer.alloc(10, 1));
    await writeFile(join(fixture, "cache", "fresh", "new.bin"), Buffer.alloc(1000, 2));
    await writeFile(join(fixture, "red", "Keychains", "secret.bin"), Buffer.alloc(5000, 3));
    await writeFile(join(fixture, "tiny", "one.bin"), Buffer.alloc(10, 4));
    await writeFile(join(fixture, "aged", "old.bin"), Buffer.alloc(2048, 5));
    const old = new Date(Date.now() - 90 * 86_400_000);
    await utimes(join(fixture, "cache", "big.bin"), old, old);
    await utimes(join(fixture, "aged", "old.bin"), old, old);
    await utimes(join(fixture, "aged"), old, old);
    await writeRules(
      `- id: test.cache\n  tier: green\n  desc: cache test\n  paths: { all: "${fixture}/cache" }\n  minAgeDays: 30\n` +
        `- id: test.red\n  tier: green\n  desc: red test\n  paths: { all: "${fixture}/red/Keychains" }\n` +
        `- id: test.tiny\n  tier: green\n  desc: tiny test\n  paths: { all: "${fixture}/tiny" }\n` +
        `- id: test.aged\n  tier: green\n  desc: aged test\n  paths: { all: "${fixture}/aged" }\n`,
    );
  });

  test("reports byte totals, newest mtime and a fresh downgrade", async () => {
    const report = await scan({ roots: [fixture] });
    expect(report.platform).toBe(process.platform === "darwin" ? "mac" : process.platform === "win32" ? "win" : "linux");
    expect(report.scannedMs).toBeGreaterThanOrEqual(0);
    expect(report.reclaimable).toBe(report.totals.green.bytes + report.totals.yellow.bytes);
    expect(report.freeBefore).toBeGreaterThan(0);

    const hit = report.findings.find((f) => f.ruleId === "test.cache");
    expect(hit?.bytes).toBe(4096 + 10 + 1000);
    expect(hit?.tier).toBe("yellow");
    expect(hit?.ageDays).toBeLessThan(1);
    expect(hit?.note).toMatch(/mới 0\.\d ngày/);
    expect(hit?.verified).toBe(true);
    expect(report.totals.yellow.bytes).toBeGreaterThan(0);
  });

  test("ageDays comes from the newest mtime in the tree", async () => {
    const aged = (await scan({ roots: [fixture] })).findings.find((f) => f.ruleId === "test.aged");
    expect(aged?.bytes).toBe(2048);
    expect(aged?.ageDays).toBeGreaterThan(85);
    expect(aged?.ageDays).toBeLessThan(95);
    expect(aged?.tier).toBe("green");
    expect(aged?.note).toBe("");
  });

  test("never emits a red path", async () => {
    const report = await scan({ roots: [fixture] });
    expect(report.findings.some((f) => f.path.includes("Keychains"))).toBe(false);
    expect(report.findings.some((f) => f.ruleId === "test.red")).toBe(false);
  });

  test("minBytes filters small findings", async () => {
    const report = await scan({ roots: [fixture], minBytes: 1000 });
    expect(report.findings.some((f) => f.ruleId === "test.tiny")).toBe(false);
    expect(report.findings.some((f) => f.ruleId === "test.cache")).toBe(true);
    expect(report.findings.every((f) => f.bytes >= 1000)).toBe(true);
  });
});

describe("apply", () => {
  test("refuses red paths, HOME, HOME's parent and filesystem root", async () => {
    const allowed = join(sandbox, "allowed");
    await mkdir(allowed, { recursive: true });
    const targets = [HOME + "/Documents/notes", HOME, dirname(HOME), "/", allowed];
    const result = await apply(report(targets.map((path) => finding(path))), { assumeYes: true, tiers: { "test.cache": "green" } });
    expect(result.outcomes.map((o) => o.status)).toEqual(["failed", "failed", "failed", "failed", "deleted"]);
    expect(result.outcomes[0]?.detail).toMatch(/danh sách đỏ/);
    expect(result.outcomes[1]?.detail).toMatch(/HOME/);
    expect(result.outcomes[2]?.detail).toMatch(/HOME/);
    expect(result.outcomes[3]?.detail).toMatch(/filesystem root/);
    expect(await exists(allowed)).toBe(false);
    expect(await exists(HOME)).toBe(true);
  });

  test("skips yellow without a prompt or --yes, honours onPrompt", async () => {
    const victim = join(sandbox, "yellow");
    await mkdir(victim, { recursive: true });
    const yellow: Finding = { ...finding(victim), tier: "yellow" };

    const quiet = await apply(report([yellow]), { tiers: { "test.cache": "yellow" } });
    expect(quiet.outcomes[0]?.status).toBe("skipped");
    expect(quiet.outcomes[0]?.detail).toMatch(/cần xác nhận/);
    expect(await exists(victim)).toBe(true);

    const declined = await apply(report([yellow]), { tiers: { "test.cache": "yellow" }, onPrompt: async () => false });
    expect(declined.outcomes[0]?.status).toBe("skipped");
    expect(declined.outcomes[0]?.detail).toMatch(/từ chối/);
    expect(await exists(victim)).toBe(true);

    const accepted = await apply(report([yellow]), { tiers: { "test.cache": "yellow" }, onPrompt: async () => true });
    expect(accepted.outcomes[0]?.status).toBe("deleted");
    expect(await exists(victim)).toBe(false);
  });

  test("reports freed as the measured disk delta between freeBefore and freeAfter", async () => {
    const hog = join(sandbox, "hog");
    await mkdir(hog, { recursive: true });
    await writeFile(join(hog, "a.bin"), Buffer.alloc(16 * 1024 * 1024, 4));
    const freeBefore = await freeSpace(HOME);
    const result = await apply(report([finding(hog, 16 * 1024 * 1024)], freeBefore), { assumeYes: true, tiers: { "test.cache": "green" } });
    expect(result.outcomes[0]?.status).toBe("deleted");
    expect(result.freeBefore).toBe(freeBefore);
    expect(result.freeAfter).toBeGreaterThan(0);
    expect(result.freed).toBe(Math.max(0, result.freeAfter - result.freeBefore));
    expect(result.elapsedMs).toBeGreaterThanOrEqual(0);
  });
});
describe("verification block", () => {
  test("--yes cannot delete a finding whose verification failed", async () => {
    const victim = join(sandbox, "gradle-cache-in-use");
    await mkdir(victim, { recursive: true });
    await writeFile(join(victim, "junk.bin"), Buffer.alloc(4 * 1024 * 1024, 7));
    const blocked = {
      ...finding(victim, 4 * 1024 * 1024),
      tier: "yellow" as const,
      verified: false,
      blocked: true,
      note: "KHÔNG XÓA: project /x/android uses Gradle 8.14",
    };
    const result = await apply(report([blocked]), {
      assumeYes: true,
      tiers: { "test.cache": "yellow" },
    });
    expect(result.outcomes[0]?.status).toBe("skipped");
    expect(result.outcomes[0]?.detail).toContain("KIỆM SOÁT CHẶN");
    expect(await exists(victim)).toBe(true);
  });
});
