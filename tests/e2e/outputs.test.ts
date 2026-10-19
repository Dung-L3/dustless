import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import {
  applyJson,
  cleanupAll,
  digest,
  measuredFreed,
  MB,
  plant,
  sandbox,
  scanJson,
  currentPlatform,
  treeBytes,
  userRules,
  type Sandbox,
} from "./harness.ts";

afterAll(cleanupAll);

describe("8. red paths are never deleted, even with --yes", () => {
  let box: Sandbox;
  const victims = [".git", "Library/Keychains", "Documents", "data.db-wal"];

  beforeAll(async () => {
    box = await sandbox("red");
    for (const victim of victims) await plant(join(box.home, victim), 256 * 1024, 1);
    await userRules(
      box.home,
      `- id: test.red\n  tier: green\n  desc: red probe\n  paths:\n    all:\n` +
        victims.map((v) => `      - "${join(box.home, v)}"`).join("\n"),
    );
  });

  afterAll(async () => {
    await box.dispose();
  });

  test("a green rule aimed straight at red paths yields no findings at all", async () => {
    const run = await box.run(["scan", "--json"]);
    expect(run.code).toBe(0);
    expect(scanJson(run.stdout).findings).toEqual([]);
  });

  test("apply --yes leaves every red path byte-for-byte intact", async () => {
    const before = new Map(await Promise.all(victims.map(async (v) => [v, await digest(join(box.home, v))] as const)));
    const run = await box.run(["apply", "--yes"]);
    expect(run.code).toBe(0);
    expect(run.stdout).not.toContain("deleted");
    for (const victim of victims) {
      const current = await digest(join(box.home, victim));
      expect(current).toBe(before.get(victim) ?? "");
      expect(current).not.toBe("");
      expect(await treeBytes(join(box.home, victim))).toBe(256 * 1024);
    }
  });
});

describe("9. idempotency", () => {
  let box: Sandbox;
  beforeAll(async () => {
    box = await sandbox("idem");
    await plant(join(box.home, ".npm", "_cacache"), 2 * MB, 2);
    await plant(join(box.home, ".bun", "install", "cache"), 2 * MB, 2);
  });
  afterAll(async () => {
    await box.dispose();
  });

  test("a second scan after apply reports zero findings for the cleaned rules", async () => {
    expect(scanJson((await box.run(["scan", "--json"])).stdout).findings.length).toBe(2);
    expect((await box.run(["apply", "--yes"])).code).toBe(0);
    const after = scanJson((await box.run(["scan", "--json"])).stdout);
    expect(after.findings.map((f) => f.ruleId)).toEqual([]);
    expect(after.reclaimable).toBe(0);
  });

  test("running apply twice more changes nothing and still exits 0", async () => {
    expect((await box.run(["apply", "--yes"])).code).toBe(0);
    expect((await box.run(["apply", "--yes"])).code).toBe(0);
    expect(scanJson((await box.run(["scan", "--json"])).stdout).findings).toEqual([]);
  });
});

describe("10. JSON output", () => {
  let box: Sandbox;
  beforeAll(async () => {
    box = await sandbox("json");
    await plant(join(box.home, ".npm", "_cacache"), 2 * MB, 2);
  });
  afterAll(async () => {
    await box.dispose();
  });

  test("scan --json carries the documented shape with correct values", async () => {
    const run = await box.run(["scan", "--json"]);
    expect(run.code).toBe(0);
    const report = scanJson(run.stdout);
    expect(report.findings[0]?.ruleId).toBe("npm.cacache");
    expect(report.findings[0]?.bytes).toBe(2 * MB);
    expect(report.totals["green"]).toEqual({ count: 1, bytes: 2 * MB });
    expect(report.reclaimable).toBe(2 * MB);
    expect(report.freeBefore).toBeGreaterThan(0);
    expect(run.stdout.trimEnd().split("\n")).toHaveLength(1);
  });

  test("apply --json reports outcomes and freed bytes", async () => {
    const run = await box.run(["apply", "--yes", "--json"]);
    expect(run.code).toBe(0);
    const result = applyJson(run.stdout);
    expect(result.outcomes).toHaveLength(1);
    expect(result.outcomes[0]?.status).toBe("deleted");
    expect(result.freed).toBe(measuredFreed(result));
  });

  test("rule list --json and doctor --json agree on the rule count", async () => {
    const listed = JSON.parse((await box.run(["rule", "list", "--json"])).stdout) as { id: string; tier: string }[];
    expect(listed.length).toBeGreaterThan(20);
    expect(listed.some((r) => r.id === "gradle.version_cache")).toBe(true);
    const doc = await box.run(["doctor", "--json"]);
    expect(doc.code).toBe(0);
    expect((JSON.parse(doc.stdout) as { rules: number }).rules).toBe(listed.length);
  });

  test("BUG: apply --json still parses when nothing is deletable", async () => {
    const empty = await sandbox("json-empty");
    const run = await empty.run(["apply", "--yes", "--json"]);
    expect(run.code).toBe(0);
    expect(() => JSON.parse(run.stdout)).not.toThrow();
    await empty.dispose();
  });

  test("BUG: apply --json still parses when it cancels for want of confirmation", async () => {
    const run = await box.run(["apply", "--json"]);
    expect(run.code).toBe(0);
    expect(() => JSON.parse(run.stdout)).not.toThrow();
  });

  test("BUG: apply --json reports freeBefore and freeAfter, not just freed", async () => {
    const fresh = await sandbox("json-freed");
    await plant(join(fresh.home, ".npm", "_cacache"), 2 * MB, 2);
    const run = await fresh.run(["apply", "--yes", "--json"]);
    const report = JSON.parse(run.stdout) as { freed: number; freeBefore: number; freeAfter: number };
    expect(report["freeBefore"]).toBeGreaterThan(0);
    expect(report["freeAfter"]).toBeGreaterThan(0);
    expect(report["freed"]).toBe(measuredFreed(report));
    await fresh.dispose();
  });
});

describe("11. rule subcommand", () => {
  let box: Sandbox;
  beforeAll(async () => {
    box = await sandbox("rule");
  });
  afterAll(async () => {
    await box.dispose();
  });

  test("rule list prints the database and names its source", async () => {
    const run = await box.run(["rule", "list"]);
    expect(run.code).toBe(0);
    expect(run.stdout).toContain("gradle.version_cache");
    expect(run.stdout).toMatch(/rule · nguồn: (\S*rules\.yaml|default-rules\.yaml)/);
  });

  test("rule validate accepts a good file and rejects a missing one", async () => {
    const good = join(box.home, "good.yaml");
    await writeFile(good, '- id: good.one\n  tier: green\n  desc: ok\n  paths: { all: "~/x" }\n');
    const ok = await box.run(["rule", "validate", good]);
    expect(ok.code).toBe(0);
    expect(ok.stdout).toContain("OK");
    const missing = await box.run(["rule", "validate", join(box.home, "nope.yaml")]);
    expect(missing.code).toBe(1);
    expect(missing.stderr).toContain("không tìm thấy file rules");
  });

  test("rule validate names the offending rule id on a broken file", async () => {
    const file = join(box.home, "broken.yaml");
    await writeFile(
      file,
      '- id: good.one\n  tier: green\n  desc: ok\n  paths: { all: "~/x" }\n' +
        '- id: bad.rule\n  tier: purple\n  desc: nope\n  paths: { all: "~/y" }\n',
    );
    const run = await box.run(["rule", "validate", file]);
    expect(run.code).toBe(1);
    expect(run.stderr).toContain("bad.rule");
    expect(run.stderr).toContain("tier phải là green|yellow");
    expect(run.stdout).toBe("");
  });

  test("rule add appends a rule the merged database then accepts", async () => {
    const run = await box.run(["rule", "add", "my.rule", "green", "desc của tôi", "download", join(box.home, ".mycache")]);
    expect(run.code).toBe(0);
    expect(run.stdout).toContain("my.rule");
    const listed = JSON.parse((await box.run(["rule", "list", "--json"])).stdout) as { id: string; tier: string }[];
    expect(listed.find((r) => r.id === "my.rule")?.tier).toBe("green");
    expect((await box.run(["rule", "validate"])).code).toBe(0);
  });

  test("rule add refuses a rule without a recovery label", async () => {
    const run = await box.run(["rule", "add", "my.other", "green", "desc", join(box.home, ".othercache")]);
    expect(run.code).toBe(1);
    expect(run.stdout).toBe("");
    expect((await box.run(["rule", "list", "--json"])).stdout).not.toContain("my.other");
  });

  test("rule add validates the whole rule before writing anything", async () => {
    const before = (await box.run(["rule", "list", "--json"])).stdout;
    const badTier = await box.run(["rule", "add", "my.badtier", "purple", "desc", "download", join(box.home, ".bad")]);
    expect(badTier.code).toBe(1);
    expect(badTier.stderr).toContain("green|yellow");
    const badId = await box.run(["rule", "add", "my bad id", "green", "desc", "download", join(box.home, ".bad")]);
    expect(badId.code).toBe(1);
    expect(badId.stderr).toContain("id");
    expect((await box.run(["rule", "list", "--json"])).stdout).toBe(before);
    expect((await box.run(["rule", "validate"])).code).toBe(0);
  });

  test("rule show prints one rule as JSON and rejects an unknown id", async () => {
    const shown = await box.run(["rule", "show", "gradle.version_cache"]);
    expect(shown.code).toBe(0);
    expect((JSON.parse(shown.stdout) as { id: string }).id).toBe("gradle.version_cache");
    const missing = await box.run(["rule", "show", "no.such.rule"]);
    expect(missing.code).toBe(1);
    expect(missing.stderr).toContain("no.such.rule");
  });
});

describe("12. doctor", () => {
  let box: Sandbox;
  beforeAll(async () => {
    box = await sandbox("doctor");
  });
  afterAll(async () => {
    await box.dispose();
  });

  test("exits 0 and names the platform and the rule count", async () => {
    const run = await box.run(["doctor"]);
    expect(run.code).toBe(0);
    expect(run.stdout).toContain(currentPlatform());
    expect(run.stdout).toMatch(/rules\s+2\d/);
    expect(run.stdout).toContain("~/.npm/_cacache");
  });

  test("reports the sandbox as HOME, never the real one", async () => {
    const run = await box.run(["doctor", "--json"]);
    const report = JSON.parse(run.stdout) as { home: string; configDir: string };
    expect(report.home).toBe(box.home);
    expect(report.home).toContain("dustless-e2e-");
    expect(report.configDir.startsWith(box.home)).toBe(true);
  });
});