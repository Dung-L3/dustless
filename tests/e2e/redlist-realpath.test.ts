import { afterAll, describe, expect, test } from "bun:test";
import { mkdir, readFile, stat, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import {
  applyJson,
  cleanupAll,
  digest,
  sandbox,
  scanJson,
  treeBytes,
  userRules,
  type Sandbox,
} from "./harness.ts";

const exists = async (path: string): Promise<boolean> =>
  await stat(path).then(() => true, () => false);

const RULES = `
- id: projs.leaf
  tier: green
  desc: scratch trees
  paths: { all: "~/projs/*" }
  recoveryLabel: download
- id: projs.through
  tier: green
  desc: named file through a scratch tree
  paths: { all: "~/projs/*/canary.txt" }
  recoveryLabel: download
`;

type Scene = {
  box: Sandbox;
  redDir: string;
  canary: string;
  content: string;
  outside: string;
  plain: string;
  portal: string;
  portalTrailing: string;
};

async function scene(label: string): Promise<Scene> {
  const box = await sandbox(label);
  const redDir = join(box.home, "Documents");
  const canary = join(redDir, "canary.txt");
  const content = `CANARY-${label}-${Date.now()}-do-not-delete`;
  await mkdir(redDir, { recursive: true });
  await writeFile(canary, content);
  const projs = join(box.home, "projs");
  const plain = join(projs, "plain");
  const portal = join(projs, "portal");
  const portalTrailing = join(projs, "portal-trailing");
  await mkdir(plain, { recursive: true });
  await writeFile(join(plain, "scratch.txt"), Buffer.alloc(4096, 0x41));
  await symlink(redDir, portal);
  await symlink(redDir + "/", portalTrailing);
  await writeFile(join(box.outside, "untouched.txt"), `OUTSIDE-${label}`);
  await userRules(box.home, RULES);
  return { box, redDir, canary, content, outside: box.outside, plain, portal, portalTrailing };
}

async function assertCanary(s: Scene): Promise<void> {
  expect(await exists(s.canary)).toBe(true);
  expect(await readFile(s.canary, "utf8")).toBe(s.content);
  expect(await treeBytes(s.redDir)).toBeGreaterThan(0);
}

afterAll(cleanupAll);

describe("real-path red filtering through the compiled binary", () => {
  test("scan drops symlink leaves and files reached through them into a red directory", async () => {
    const s = await scene("scan");
    const report = scanJson((await s.box.run(["scan", "--json"])).stdout);
    expect(report.findings.filter((f) => f.ruleId === "projs.leaf").map((f) => f.path)).toEqual([s.plain]);
    expect(report.findings.filter((f) => f.ruleId === "projs.through")).toEqual([]);
    const through = report.unscannable.find((r) => r.ruleId === "projs.through");
    expect(through?.reason).toBe("red");
    await s.box.dispose();
  });

  test("apply --yes deletes the clean leaf and leaves both portals and the red canary intact", async () => {
    const s = await scene("apply");
    const beforeRed = await digest(s.redDir);
    const beforeOutside = await digest(s.outside);
    const run = await s.box.run(["apply", "--yes", "--json"]);
    expect(run.code).toBe(0);
    const report = applyJson(run.stdout);
    expect(report.outcomes.map((o) => o.path)).toEqual([s.plain]);
    expect(await exists(s.plain)).toBe(false);
    expect(await exists(s.portal)).toBe(true);
    expect(await exists(s.portalTrailing)).toBe(true);
    await assertCanary(s);
    expect(await digest(s.redDir)).toBe(beforeRed);
    expect(await digest(s.outside)).toBe(beforeOutside);
    await s.box.dispose();
  });

  test("apply --only-file deletes only the selected clean leaf", async () => {
    const s = await scene("onlyfile");
    const selection = join(s.box.home, "selection.json");
    await writeFile(
      selection,
      JSON.stringify([
        s.plain,
        s.portal,
        s.portalTrailing,
        join(s.portal, "canary.txt"),
        join(s.portalTrailing, "canary.txt"),
      ]),
    );
    const beforeRed = await digest(s.redDir);
    const run = await s.box.run(["apply", "--yes", "--json", "--only-file", selection]);
    expect(run.code).toBe(0);
    const outcomes = applyJson(run.stdout).outcomes;
    expect(outcomes.filter((o) => o.status === "deleted").map((o) => o.path)).toEqual([s.plain]);
    expect(outcomes.filter((o) => o.path.includes("portal"))).toEqual([]);
    expect(await exists(s.plain)).toBe(false);
    expect(await exists(s.portal)).toBe(true);
    expect(await exists(s.portalTrailing)).toBe(true);
    await assertCanary(s);
    expect(await digest(s.redDir)).toBe(beforeRed);
    await s.box.dispose();
  });

  test("largefiles refuses the portals, a trailing separator and paths through them", async () => {
    const s = await scene("largefiles");
    const beforeRed = await digest(s.redDir);
    for (const target of [
      s.portal,
      s.portal + "/",
      s.portalTrailing,
      join(s.portal, "canary.txt"),
      s.canary,
    ]) {
      const run = await s.box.run(["largefiles", "--delete", target, "--confirm", "--json"]);
      expect(run.code).toBe(1);
      const report = JSON.parse(run.stdout) as { outcomes: Array<{ status: string; detail: string }> };
      expect(report.outcomes[0]?.status).toBe("failed");
      expect(report.outcomes[0]?.detail).toContain("red list");
      expect(await exists(s.portal)).toBe(true);
      expect(await exists(s.portalTrailing)).toBe(true);
      await assertCanary(s);
      expect(await digest(s.redDir)).toBe(beforeRed);
    }
    await s.box.dispose();
  });
});
