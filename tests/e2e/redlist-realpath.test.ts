import { afterAll, describe, expect, test } from "bun:test";
import { mkdir, readFile, stat, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import {
  applyJson,
  cleanupAll,
  digest,
  sandbox,
  treeBytes,
  userRules,
  type Sandbox,
} from "./harness.ts";

const exists = async (path: string): Promise<boolean> =>
  await stat(path).then(() => true, () => false);

const RULES_CLEAN = `
- id: projs-clean
  desc: cleans scratch trees under ~/projs
  tier: green
  paths: { all: "~/projs/*" }
`;

const RULES_THROUGH = `${RULES_CLEAN}
- id: projs-through
  desc: reaches a named file through a sandbox leaf
  tier: green
  paths: { all: "~/projs/*/canary.txt" }
`;

type Scene = {
  box: Sandbox;
  redDir: string;
  canary: string;
  content: string;
  portal: string;
  portalTrailing: string;
};

async function scene(label: string, rules: string): Promise<Scene> {
  const box = await sandbox(label);
  const redDir = join(box.home, "Documents");
  const canary = join(redDir, "canary.txt");
  const content = `CANARY-${label}-${Date.now()}-do-not-delete`;
  await mkdir(redDir, { recursive: true });
  await writeFile(canary, content);
  const cleanDir = join(box.home, "projs");
  const plain = join(cleanDir, "plain");
  await mkdir(plain, { recursive: true });
  await writeFile(join(plain, "scratch.txt"), Buffer.alloc(4096, 0x41));
  const portal = join(cleanDir, "portal");
  const portalTrailing = join(cleanDir, "portal-trailing");
  await symlink(redDir, portal);
  await symlink(redDir + "/", portalTrailing);
  await writeFile(join(box.outside, "untouched.txt"), `OUTSIDE-${label}`);
  await userRules(box.home, rules);
  return { box, redDir, canary, content, portal, portalTrailing };
}

async function assertCanaryUntouched(
  s: Scene,
  route: string,
  beforeRedDigest: string,
): Promise<void> {
  if (!(await exists(s.canary))) {
    throw new Error(
      `P0 data-loss via ${route}: red canary ${s.canary} was deleted`,
    );
  }
  expect(await readFile(s.canary, "utf8")).toBe(s.content);
  expect(await digest(s.redDir)).toBe(beforeRedDigest);
  expect(await treeBytes(s.redDir)).toBeGreaterThan(0);
}

afterAll(cleanupAll);

describe("redlist-realpath: deletion routes may not reach behind a symlink into a red directory", () => {
  test("apply --yes with a rule-matched leaf path through a symlink must not delete the red canary", async () => {
    const s = await scene("apply-through", RULES_THROUGH);
    const beforeRed = await digest(s.redDir);
    const beforeOutside = await digest(s.box.outside);
    const run = await s.box.run(["apply", "--yes", "--json"]);
    const stillThere = await exists(s.canary);
    expect(stillThere, `apply --yes deleted ${s.canary}`).toBe(true);
    expect(await readFile(s.canary, "utf8")).toBe(s.content);
    expect(await digest(s.redDir)).toBe(beforeRed);
    expect(await treeBytes(s.redDir)).toBeGreaterThan(0);
    expect(await digest(s.box.outside)).toBe(beforeOutside);
    const report = applyJson(run.stdout);
    expect(report.outcomes.length).toBeGreaterThan(0);
    const through = report.outcomes.find(
      (o) =>
        o.path === join(s.portal, "canary.txt") ||
        o.path === join(s.portalTrailing, "canary.txt"),
    );
    expect(through?.status).toBe("failed");
    expect(through?.detail ?? "").toContain("danh sách đỏ");
  });

  test("apply --yes refuses symlinked leaves that resolve into the red directory, preserving the canary, the red directory and the links", async () => {
    const s = await scene("apply-links", RULES_CLEAN);
    const beforeRed = await digest(s.redDir);
    const beforeOutside = await digest(s.box.outside);
    const run = await s.box.run(["apply", "--yes", "--json"]);
    if (!(await exists(s.canary))) {
      const report = applyJson(run.stdout);
      throw new Error(
        `P0 data-loss via apply --yes on the symlink leaf itself: ${s.canary} deleted: ${JSON.stringify(report.outcomes)}`,
      );
    }
    expect(await readFile(s.canary, "utf8")).toBe(s.content);
    expect(await digest(s.redDir)).toBe(beforeRed);
    expect(await treeBytes(s.redDir)).toBeGreaterThan(0);
    expect(await digest(s.box.outside)).toBe(beforeOutside);
    expect(await exists(s.portal)).toBe(true);
    expect(await exists(s.portalTrailing)).toBe(true);
    const report = applyJson(run.stdout);
    for (const link of [s.portal, s.portalTrailing]) {
      const outcome = report.outcomes.find((o) => o.path === link);
      expect(outcome?.status).toBe("failed");
      expect(outcome?.detail ?? "").toContain("danh sách đỏ");
    }
  });

  test("apply --only-file whose selection names the links and a path through them must not carry the canary away", async () => {
    const s = await scene("onlyfile-through", RULES_THROUGH);
    const beforeRed = await digest(s.redDir);
    const beforeOutside = await digest(s.box.outside);
    const selection = join(s.box.home, "selection.json");
    await writeFile(
      selection,
      JSON.stringify([
        s.portal,
        s.portalTrailing,
        join(s.portal, "canary.txt"),
        join(s.portalTrailing, "canary.txt"),
      ]),
    );
    const run = await s.box.run([
      "apply",
      "--yes",
      "--json",
      "--only-file",
      selection,
    ]);
    if (!(await exists(s.canary))) {
      const report = applyJson(run.stdout);
      throw new Error(
        `P0 data-loss via apply --only-file: ${s.canary} deleted through selection ${selection}: ${JSON.stringify(report.outcomes)}`,
      );
    }
    expect(await readFile(s.canary, "utf8")).toBe(s.content);
    expect(await digest(s.redDir)).toBe(beforeRed);
    expect(await treeBytes(s.redDir)).toBeGreaterThan(0);
    expect(await digest(s.box.outside)).toBe(beforeOutside);
    const report = applyJson(run.stdout);
    const through = report.outcomes.find(
      (o) =>
        o.path === join(s.portal, "canary.txt") ||
        o.path === join(s.portalTrailing, "canary.txt"),
    );
    expect(through?.status).toBe("failed");
    expect(through?.detail ?? "").toContain("danh sách đỏ");
  });

  test("largefiles --delete refuses symlink leaves that resolve into the red directory and preserves the canary", async () => {
    const s = await scene("largefiles-symlink", RULES_CLEAN);
    const beforeRed = await digest(s.redDir);
    const beforeOutside = await digest(s.box.outside);
    const leaf = s.portal + "/";
    for (const [name, target] of [
      ["symlink leaf", s.portal],
      ["trailing-slash symlink", leaf],
      ["trailing-target symlink", s.portalTrailing],
    ] as const) {
      const run = await s.box.run([
        "largefiles",
        "--delete",
        target,
        "--confirm",
        "--json",
      ]);
      expect(run.code).toBe(1);
      const report = applyJson(run.stdout) as {
        outcomes: Array<{ path: string; status: string }>;
      };
      const outcome = report.outcomes.find((o) =>
        o.path.replace(/\/+$/, "") === s.portal || o.path === s.portalTrailing);
      expect(outcome?.status).toBe("failed");
      await assertCanaryUntouched(s, `largefiles --delete on ${name}`, beforeRed);
    }
    expect(await digest(s.box.outside)).toBe(beforeOutside);
  });

  test("largefiles --delete of a file reached through the symlink must refuse (the real path is red)", async () => {
    const s = await scene("largefiles-through", RULES_CLEAN);
    const beforeRed = await digest(s.redDir);
    const beforeOutside = await digest(s.box.outside);
    const target = join(s.portal, "canary.txt");
    const run = await s.box.run([
      "largefiles",
      "--delete",
      target,
      "--confirm",
      "--json",
    ]);
    if (!(await exists(s.canary))) {
      throw new Error(
        `P0 data-loss via largefiles --delete ${target}: canary ${s.canary} was trashed or deleted: ${run.stdout}`,
      );
    }
    expect(await readFile(s.canary, "utf8")).toBe(s.content);
    expect(await digest(s.redDir)).toBe(beforeRed);
    expect(await treeBytes(s.redDir)).toBeGreaterThan(0);
    expect(await digest(s.box.outside)).toBe(beforeOutside);
  });

  test("largefiles --delete of the lexically red Documents/canary.txt refuses and preserves the canary", async () => {
    const s = await scene("largefiles-direct-red", RULES_CLEAN);
    const beforeRed = await digest(s.redDir);
    const beforeOutside = await digest(s.box.outside);
    const run = await s.box.run([
      "largefiles",
      "--delete",
      s.canary,
      "--confirm",
      "--json",
    ]);
    expect(run.code).toBe(1);
    const report = applyJson(run.stdout) as {
      outcomes: Array<{ path: string; status: string; detail: string }>;
    };
    expect(report.outcomes[0]?.status).toBe("failed");
    expect(report.outcomes[0]?.detail).toContain("red list");
    await assertCanaryUntouched(s, "largefiles --delete on the direct red path", beforeRed);
    expect(await digest(s.box.outside)).toBe(beforeOutside);
  });
});
