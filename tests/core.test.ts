import { afterAll, beforeAll, describe, expect, mock, test } from "bun:test";
import { chmod, mkdir, mkdtemp, readFile, rm, stat, symlink, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import type { Finding, ScanReport } from "../src/types.ts";
import { HOME, isRed } from "../src/core/paths.ts";
import { loadRules, userRulesPath } from "../src/core/rules.ts";
import { freeSpace } from "../src/core/space.ts";
import { scan, withinRoots } from "../src/core/scan.ts";
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
  unscannable: [],
  unscannableSummary: { absent: 0, no_access: 0, not_supported: 0, error: 0, red: 0 },
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
  const outside = `${fixture}-outside`;
  const exact = join(sandbox, "exact-root");

  beforeAll(async () => {
    await mkdir(join(fixture, "cache", "fresh"), { recursive: true });
    await mkdir(join(fixture, "red", "Keychains"), { recursive: true });
    await mkdir(join(fixture, "tiny"), { recursive: true });
    await mkdir(join(fixture, "aged"), { recursive: true });
    await mkdir(join(outside, "cache"), { recursive: true });
    await mkdir(exact, { recursive: true });
    await writeFile(join(fixture, "cache", "big.bin"), Buffer.alloc(4096, 7));
    await writeFile(join(fixture, "cache", "small.bin"), Buffer.alloc(10, 1));
    await writeFile(join(fixture, "cache", "fresh", "new.bin"), Buffer.alloc(1000, 2));
    await writeFile(join(fixture, "red", "Keychains", "secret.bin"), Buffer.alloc(5000, 3));
    await writeFile(join(fixture, "tiny", "one.bin"), Buffer.alloc(10, 4));
    await writeFile(join(fixture, "aged", "old.bin"), Buffer.alloc(2048, 5));
    await writeFile(join(outside, "cache", "other.bin"), Buffer.alloc(2048, 6));
    await writeFile(join(exact, "root.bin"), Buffer.alloc(1024, 8));
    const old = new Date(Date.now() - 90 * 86_400_000);
    await utimes(join(fixture, "cache", "big.bin"), old, old);
    await utimes(join(fixture, "aged", "old.bin"), old, old);
    await utimes(join(fixture, "aged"), old, old);
    await writeRules(
      `- id: test.cache\n  tier: green\n  desc: cache test\n  paths: { all: "${fixture}/cache" }\n  minAgeDays: 30\n` +
        `- id: test.red\n  tier: green\n  desc: red test\n  paths: { all: "${fixture}/red/Keychains" }\n` +
        `- id: test.tiny\n  tier: green\n  desc: tiny test\n  paths: { all: "${fixture}/tiny" }\n` +
        `- id: test.aged\n  tier: green\n  desc: aged test\n  paths: { all: "${fixture}/aged" }\n` +
        `- id: test.outside\n  tier: green\n  desc: sibling test\n  paths: { all: "${outside}/cache" }\n` +
        `- id: test.exact\n  tier: green\n  desc: exact root test\n  paths: { all: "${exact}" }\n`,
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

  test("roots match on a path boundary, not a string prefix", async () => {
    const inside = await scan({ roots: [fixture] });
    expect(inside.findings.some((f) => f.ruleId === "test.outside")).toBe(false);
    const sibling = await scan({ roots: [outside] });
    expect(sibling.findings.some((f) => f.ruleId === "test.outside")).toBe(true);
    expect(sibling.findings.some((f) => f.ruleId === "test.cache")).toBe(false);
  });

  test("a root includes itself and the filesystem root keeps its separator", async () => {
    expect(withinRoots(exact, [exact])).toBe(true);
    expect(withinRoots(`${exact}/child`, [exact])).toBe(true);
    expect(withinRoots(outside, [exact])).toBe(false);
    expect(withinRoots("/tmp/x", ["/"])).toBe(true);
    expect(withinRoots("/", ["/"])).toBe(true);
    const report = await scan({ roots: [exact] });
    expect(report.findings.some((f) => f.ruleId === "test.exact")).toBe(true);
  });
});

describe("apply", () => {
  test("refuses red paths, HOME, HOME's parent and filesystem root", async () => {
    const allowed = join(sandbox, "allowed");
    await mkdir(allowed, { recursive: true });
    const homeLink = join(sandbox, "home-link");
    const parentLink = join(sandbox, "parent-link");
    const rootLink = join(sandbox, "root-link");
    await symlink(HOME, homeLink);
    await symlink(dirname(HOME), parentLink);
    await symlink("/", rootLink);
    const targets = [join(sandbox, "Documents", "notes"), homeLink, parentLink, rootLink, allowed];
    const result = await apply(report(targets.map((path) => finding(path))), { assumeYes: true, tiers: { "test.cache": "green" } });
    expect(result.outcomes.map((o) => o.status)).toEqual(["failed", "failed", "failed", "failed", "deleted"]);
    expect(result.outcomes[0]?.detail).toMatch(/danh sách đỏ/);
    for (const index of [1, 2, 3]) expect(result.outcomes[index]?.detail).toMatch(/HOME/);
    expect(await exists(allowed)).toBe(false);
    expect(await exists(HOME)).toBe(true);
    expect(await exists(homeLink)).toBe(true);
    expect(await exists(parentLink)).toBe(true);
    expect(await exists(rootLink)).toBe(true);
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

  test("a yellow finding is not deleted under a green rule choice without confirmation", async () => {
    const victim = join(sandbox, "yellow-strict");
    await mkdir(victim, { recursive: true });
    const yellow: Finding = { ...finding(victim), tier: "yellow" };
    const result = await apply(report([yellow]), { tiers: { "test.cache": "green" } });
    expect(result.outcomes[0]?.status).toBe("skipped");
    expect(result.outcomes[0]?.detail).toMatch(/cần xác nhận/);
    expect(await exists(victim)).toBe(true);
  });

  test("a path that disappeared before apply is skipped, not reported deleted", async () => {
    const ghost = join(sandbox, "vanished");
    const result = await apply(report([finding(ghost)]), { assumeYes: true, tiers: { "test.cache": "green" } });
    expect(result.outcomes[0]?.status).toBe("skipped");
    expect(result.outcomes[0]?.detail).toMatch(/không còn tồn tại/);
  });

  test.skipIf(process.platform === "win32")("declared and native busy processes both skip the finding", async () => {
    const bin = join(sandbox, "bin");
    await mkdir(bin, { recursive: true });
    const fakePs = join(bin, "ps");
    await writeFile(fakePs, "#!/bin/sh\necho Bun\necho npm\n");
    await chmod(fakePs, 0o755);
    const busyVictim = join(sandbox, "busy-declared");
    const nativeVictim = join(sandbox, "busy-native");
    await mkdir(busyVictim, { recursive: true });
    await mkdir(nativeVictim, { recursive: true });
    const priorRules = await readFile(userRulesPath(), "utf8").catch(() => null);
    const priorPath = process.env["PATH"];
    await writeRules(
      `- id: test.busy\n  tier: green\n  desc: busy\n  paths: { all: "${busyVictim}" }\n  busyProcesses: [" /opt/homebrew/bin/Bun "]\n` +
        `- id: test.native\n  tier: green\n  desc: native\n  paths: { all: "${nativeVictim}" }\n  nativeCommand: npm cache verify\n`,
    );
    process.env["PATH"] = `${bin}:${priorPath ?? ""}`;
    try {
      const result = await apply(
        report([{ ...finding(busyVictim), ruleId: "test.busy" }, { ...finding(nativeVictim), ruleId: "test.native" }]),
        { assumeYes: true, tiers: { "test.busy": "green", "test.native": "green" } },
      );
      expect(result.outcomes.map((o) => o.status)).toEqual(["skipped", "skipped"]);
      for (const outcome of result.outcomes) expect(outcome.detail).toMatch(/đang chạy/);
      expect(await exists(busyVictim)).toBe(true);
      expect(await exists(nativeVictim)).toBe(true);
    } finally {
      if (priorPath === undefined) delete process.env["PATH"];
      else process.env["PATH"] = priorPath;
      if (priorRules === null) await rm(userRulesPath(), { force: true });
      else await writeFile(userRulesPath(), priorRules);
    }
  });

  test("a rule id inherited from Object.prototype is not selected by an empty tier map", async () => {
    const victim = join(sandbox, "prototype");
    await mkdir(victim, { recursive: true });
    const result = await apply(report([{ ...finding(victim), ruleId: "constructor" }]), { assumeYes: true, tiers: {} });
    expect(result.outcomes[0]?.status).toBe("skipped");
    expect(result.outcomes[0]?.detail).toMatch(/không được yêu cầu/);
    expect(await exists(victim)).toBe(true);
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

describe("an explicit selection", () => {
  test("only the paths in the set are deleted; the rest is skipped", async () => {
    const picked = join(sandbox, "picked");
    const left = join(sandbox, "left-alone");
    for (const dir of [picked, left]) {
      await mkdir(dir, { recursive: true });
      await writeFile(join(dir, "blob.bin"), Buffer.alloc(64 * 1024, 3));
    }
    const result = await apply(report([finding(picked), finding(left)]), {
      assumeYes: true,
      tiers: { "test.cache": "green" },
      only: new Set([resolve(picked)]),
    });
    expect(result.outcomes.map((o) => o.status)).toEqual(["deleted", "skipped"]);
    expect(result.outcomes[1]?.detail).toMatch(/chọn/);
    expect(await exists(picked)).toBe(false);
    expect(await exists(left)).toBe(true);
  });

  test("an empty selection deletes nothing at all", async () => {
    const victim = join(sandbox, "never-selected");
    await mkdir(victim, { recursive: true });
    const result = await apply(report([finding(victim)]), {
      assumeYes: true,
      tiers: { "test.cache": "green" },
      only: new Set(),
    });
    expect(result.outcomes[0]?.status).toBe("skipped");
    expect(await exists(victim)).toBe(true);
  });

  test("an undefined selection keeps the old behaviour", async () => {
    const victim = join(sandbox, "unselected-option");
    await mkdir(victim, { recursive: true });
    const result = await apply(report([finding(victim)]), { assumeYes: true, tiers: { "test.cache": "green" } });
    expect(result.outcomes[0]?.status).toBe("deleted");
    expect(await exists(victim)).toBe(false);
  });

  test("a selection never widens past the safety guards", async () => {
    const red = join(sandbox, "Documents", "notes");
    const blocked = join(sandbox, "blocked-in-selection");
    await mkdir(red, { recursive: true });
    await mkdir(blocked, { recursive: true });
    const result = await apply(
      report([
        finding(red),
        { ...finding(blocked), tier: "yellow", blocked: true, verified: false, note: "KHÔNG XÓA: in use" },
      ]),
      { assumeYes: true, tiers: { "test.cache": "green", "test.yellow": "yellow" }, only: new Set([resolve(red), resolve(blocked)]) },
    );
    expect(result.outcomes.map((o) => o.status)).toEqual(["failed", "skipped"]);
    expect(result.outcomes[1]?.detail).toContain("KIỆM SOÁT CHẶN");
    expect(await exists(red)).toBe(true);
    expect(await exists(blocked)).toBe(true);
  });
});