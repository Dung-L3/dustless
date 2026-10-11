import { afterAll, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, symlink, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isLiveDependencyTree, npmOrPnpmLinked } from "../src/core/verify/node.ts";
import { verify } from "../src/core/verify/index.ts";
import type { Rule } from "../src/types.ts";

type StartupItemProbe = {
  label: string;
  exists: boolean;
  note: string;
};

const roots: string[] = [];

afterAll(async () => {
  await Promise.all(roots.map((path) => rm(path, { recursive: true, force: true })));
});

async function sandbox(): Promise<string> {
  const path = await mkdtemp(join(tmpdir(), "dustless-system-"));
  roots.push(path);
  return path;
}

async function plist(dir: string, name: string, program: string): Promise<void> {
  await mkdir(dir, { recursive: true });
  await writeFile(
    join(dir, `${name}.plist`),
    `<?xml version="1.0"?><plist version="1.0"><dict><key>Program</key><string>${program}</string></dict></plist>`,
  );
}

async function probeStartup(home: string): Promise<StartupItemProbe[]> {
  const script = `
    const { collectStartupItems } = await import(${JSON.stringify(join(import.meta.dir, "..", "src", "system", "startup.ts"))});
    console.log(JSON.stringify(await collectStartupItems()));
  `;
  const proc = Bun.spawn([process.execPath, "-e", script], {
    env: { ...process.env, HOME: home, NO_COLOR: "1" },
    stdout: "pipe",
    stderr: "pipe",
  });
  const out = await new Response(proc.stdout).text();
  await proc.exited;
  return JSON.parse(out) as StartupItemProbe[];
}

describe("launch agent hygiene", () => {
  const macOnly = process.platform === "darwin" ? test : test.skip;

  macOnly("a plist pointing at a deleted binary is flagged as orphaned", async () => {
    const home = await sandbox();
    await plist(join(home, "Library", "LaunchAgents"), "com.ghost.test", "/nonexistent/definitely-not-here");
    const ghost = (await probeStartup(home)).find((item) => item.label === "com.ghost.test");
    expect(ghost).toBeDefined();
    expect(ghost?.exists).toBe(false);
    expect(ghost?.note).toContain("xoá");
  });

  macOnly("a plist pointing at a real binary is not flagged", async () => {
    const home = await sandbox();
    await plist(join(home, "Library", "LaunchAgents"), "com.alive.test", "/bin/ls");
    const alive = (await probeStartup(home)).find((item) => item.label === "com.alive.test");
    expect(alive?.exists).toBe(true);
    expect(alive?.note).not.toContain("xoá");
  });

  macOnly("both cases are visible side by side", async () => {
    const home = await sandbox();
    const dir = join(home, "Library", "LaunchAgents");
    await plist(dir, "com.ghost.two", "/nonexistent/nope");
    await plist(dir, "com.alive.two", "/bin/ls");
    const items = await probeStartup(home);
    const ghost = items.find((item) => item.label === "com.ghost.two");
    const alive = items.find((item) => item.label === "com.alive.two");
    expect(ghost?.exists).toBe(false);
    expect(alive?.exists).toBe(true);
  });
});

describe("dependency tree liveness", () => {
  test("an install newer than its manifest counts as live", async () => {
    const root = await sandbox();
    const deps = join(root, "node_modules");
    await mkdir(deps, { recursive: true });
    await writeFile(join(root, "package.json"), "{}");
    await writeFile(join(deps, ".package-lock.json"), "{}");
    const past = new Date(Date.now() - 10 * 86_400_000);
    await utimes(join(root, "package.json"), past, past);
    expect(await isLiveDependencyTree(deps)).toBe(true);
  });

  test("a manifest newer than the install is stale", async () => {
    const root = await sandbox();
    const deps = join(root, "node_modules");
    await mkdir(deps, { recursive: true });
    await writeFile(join(root, "package.json"), "{}");
    await writeFile(join(deps, ".package-lock.json"), "{}");
    const older = new Date(Date.now() - 10 * 86_400_000);
    await utimes(join(deps, ".package-lock.json"), older, older);
    const newer = new Date();
    await utimes(join(root, "package.json"), newer, newer);
    expect(await isLiveDependencyTree(deps)).toBe(false);
  });

  test("symlinked entries are detected for pnpm style trees", async () => {
    const root = await sandbox();
    const deps = join(root, "node_modules");
    await mkdir(deps, { recursive: true });
    expect(await npmOrPnpmLinked(deps)).toBe(false);
    await mkdir(join(root, "real"), { recursive: true });
    await symlink(join(root, "real"), join(deps, "linked"));
    expect(await npmOrPnpmLinked(deps)).toBe(true);
  });

  test("a stale node_modules tree is blocked from deletion", async () => {
    const root = await sandbox();
    const deps = join(root, "node_modules");
    await mkdir(deps, { recursive: true });
    await writeFile(join(root, "package.json"), "{}");
    await writeFile(join(deps, ".package-lock.json"), "{}");
    const older = new Date(Date.now() - 10 * 86_400_000);
    await utimes(join(deps, ".package-lock.json"), older, older);
    const newer = new Date();
    await utimes(join(root, "package.json"), newer, newer);
    const rule: Rule = {
      id: "project.node_modules",
      tier: "yellow",
      desc: "x",
      paths: { all: deps },
      requireVerify: "git_clean",
    };
    const verdict = await verify(rule, deps);
    expect(verdict.ok).toBe(false);
    expect(verdict.note).toContain("stale");
  });
});