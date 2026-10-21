import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { applyJson, plant, sandbox, scanJson, userRules, type Sandbox } from "./harness.ts";

const exists = async (path: string): Promise<boolean> => await Bun.$`test -e ${path}`.quiet().nothrow().then((r) => r.exitCode === 0);

describe("a rule that reaches the direct children of $HOME", () => {
  let box: Sandbox;

  beforeAll(async () => {
    box = await sandbox("rule-scope");
  });

  afterAll(async () => {
    await box.dispose();
  });

  test("rule add refuses the wildcard and leaves the rules file byte-identical", async () => {
    const rulesFile = await userRules(
      box.home,
      `- id: test.seed\n  tier: green\n  desc: seed\n  recoveryLabel: download\n  paths: { all: ${JSON.stringify(join(box.home, ".seed"))} }\n`,
    );
    const before = await readFile(rulesFile);
    const run = await box.run(["rule", "add", "evil.green", "green", "test rule", "download", "~/*"]);
    expect(run.code).not.toBe(0);
    expect(run.stdout).toBe("");
    expect(run.stderr).toContain("$HOME");
    expect(await readFile(rulesFile)).toEqual(before);
    const listed = (await box.run(["rule", "list", "--json"])).stdout;
    expect(listed).not.toContain("evil.green");
  });

  test("rule add refuses every path that reaches $HOME or its parents", async () => {
    const cases = ["~", "~/..", "~/*", box.home];
    for (const [index, pattern] of cases.entries()) {
      const run = await box.run(["rule", "add", `evil.${index}`, "green", "test rule", "download", pattern]);
      expect({ pattern, code: run.code }).toEqual({ pattern, code: 1 });
      expect(run.stderr.length).toBeGreaterThan(0);
    }
    const listed = (await box.run(["rule", "list", "--json"])).stdout;
    expect(listed).not.toContain("evil.");
  });

  test("rule validate refuses a hand-written rule with the same scope", async () => {
    const file = join(box.home, "broad.yaml");
    await writeFile(
      file,
      `- id: evil.green\n  tier: green\n  desc: test rule\n  recoveryLabel: download\n  paths: { all: "~/*" }\n` +
        `- id: evil.root\n  tier: green\n  desc: test rule\n  recoveryLabel: download\n  paths: { all: "/" }\n`,
    );
    const run = await box.run(["rule", "validate", file]);
    expect(run.code).toBe(1);
    expect(run.stderr).toContain("evil.green");
  });

  test("a hand-written wildcard rule produces no finding and deletes nothing", async () => {
    const project = join(box.home, "my-project");
    await mkdir(project, { recursive: true });
    await writeFile(join(project, "canary.txt"), "keep me\n");
    await plant(join(box.home, ".config"), 2 * 1024, 2);
    await userRules(
      box.home,
      `- id: evil.green\n  tier: green\n  desc: test rule\n  recoveryLabel: download\n  paths: { all: "~/*" }\n`,
    );
    const report = scanJson((await box.run(["scan", "--json"])).stdout);
    expect(report.findings.some((f) => f.ruleId === "evil.green")).toBe(false);
    expect(report.findings.some((f) => f.path.includes("my-project"))).toBe(false);
    expect(report.reclaimable).toBe(0);
    const unscannable = report.unscannable.find((r) => r.ruleId === "evil.green");
    expect(unscannable?.reason).toBe("protected");
    const applied = applyJson((await box.run(["apply", "--yes", "--json"])).stdout);
    expect(applied.outcomes.some((o) => o.status === "deleted")).toBe(false);
    expect(await exists(join(project, "canary.txt"))).toBe(true);
    expect(await exists(project)).toBe(true);
  });

  test("a rule for the filesystem root and for $HOME yields no finding", async () => {
    await userRules(
      box.home,
      `- id: test.root\n  tier: green\n  desc: root\n  recoveryLabel: download\n  paths: { all: "/" }\n` +
        `- id: test.home\n  tier: green\n  desc: home\n  recoveryLabel: download\n  paths: { all: "~" }\n`,
    );
    const report = scanJson((await box.run(["scan", "--json"])).stdout);
    expect(report.findings).toEqual([]);
    expect(report.reclaimable).toBe(0);
    expect(report.unscannable.find((r) => r.ruleId === "test.root")?.reason).toBe("protected");
    expect(report.unscannable.find((r) => r.ruleId === "test.home")?.reason).toBe("protected");
  });
});

describe("the shipped project rules", () => {
  let box: Sandbox;

  beforeAll(async () => {
    box = await sandbox("project-rules");
    await plant(join(box.home, "d1", "node_modules"), 4 * 1024, 2);
    await plant(join(box.home, "d1", "build"), 4 * 1024, 2);
    await plant(join(box.home, "d2", "d3", "node_modules"), 4 * 1024, 2);
    await plant(join(box.home, "d2", "d3", "build"), 4 * 1024, 2);
    await plant(join(box.home, "d2", "d3", "d4", "node_modules"), 4 * 1024, 2);
    await plant(join(box.home, "d2", "d3", "d4", "build"), 4 * 1024, 2);
  });

  afterAll(async () => {
    await box.dispose();
  });

  test("node_modules and build are found at every supported depth", async () => {
    const report = scanJson((await box.run(["scan", "--json"])).stdout);
    const modules = report.findings.filter((f) => f.ruleId === "project.node_modules").map((f) => f.path);
    const builds = report.findings.filter((f) => f.ruleId === "project.build").map((f) => f.path);
    expect(modules).toContain(join(box.home, "d1", "node_modules"));
    expect(modules).toContain(join(box.home, "d2", "d3", "node_modules"));
    expect(modules).toContain(join(box.home, "d2", "d3", "d4", "node_modules"));
    expect(builds).toContain(join(box.home, "d1", "build"));
    expect(builds).toContain(join(box.home, "d2", "d3", "build"));
    expect(builds).toContain(join(box.home, "d2", "d3", "d4", "build"));
    expect(modules).toHaveLength(3);
    expect(builds).toHaveLength(3);
  });

  test("the shipped project rules are never reported as unscannable", async () => {
    const report = scanJson((await box.run(["scan", "--json"])).stdout);
    const ids = report.unscannable.map((r) => r.ruleId);
    expect(ids).not.toContain("project.node_modules");
    expect(ids).not.toContain("project.build");
  });
});
