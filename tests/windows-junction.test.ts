import { afterAll, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join, sep } from "node:path";
import { apply } from "../src/core/apply.ts";
import { findLargeFiles } from "../src/core/largefiles/index.ts";
import { moveToTrash } from "../src/core/apps/index.ts";
import type { Finding, ScanReport } from "../src/types.ts";

const exists = async (path: string): Promise<boolean> => await stat(path).then(() => true, () => false);
const roots: string[] = [];
const priorXdg = process.env["XDG_CONFIG_HOME"];

afterAll(async () => {
  if (priorXdg === undefined) delete process.env["XDG_CONFIG_HOME"];
  else process.env["XDG_CONFIG_HOME"] = priorXdg;
  for (const root of roots) await rm(root, { recursive: true, force: true });
});

async function box(): Promise<string> {
  const root = await mkdtemp(join(homedir(), ".dustless-junction-"));
  roots.push(root);
  process.env["XDG_CONFIG_HOME"] = join(root, "config");
  return root;
}

const finding = (path: string): Finding => ({
  ruleId: "test.junction",
  tier: "green",
  desc: "junction probe",
  path,
  bytes: 1024,
  mtime: 0,
  atime: 0,
  ageDays: 999,
  verified: true,
  blocked: false,
  note: "",
});

const report = (findings: Finding[]): ScanReport => ({
  findings,
  totals: { green: { count: 0, bytes: 0 }, yellow: { count: 0, bytes: 0 }, red: { count: 0, bytes: 0 }, blocked: { count: 0, bytes: 0 } },
  reclaimable: 0,
  freeBefore: 0,
  platform: "win",
  scannedMs: 0,
  unscannable: [],
  unscannableSummary: { absent: 0, no_access: 0, not_supported: 0, error: 0, red: 0 },
});

async function scene(label: string): Promise<{ root: string; target: string; junction: string; canary: string; content: string }> {
  const root = await box();
  const target = join(root, `target-${label}`);
  const junction = join(root, `cache-${label}`);
  const canary = join(target, "canary.txt");
  const content = `JUNCTION-CANARY-${label}-${Date.now()}`;
  await mkdir(target, { recursive: true });
  await writeFile(canary, content);
  await symlink(target, junction, "junction");
  return { root, target, junction, canary, content };
}

describe.skipIf(process.platform !== "win32")("Windows junction boundaries", () => {
  test("recursive apply of a junction leaf leaves the target intact", async () => {
    const s = await scene("leaf");
    const result = await apply(report([finding(s.junction)]), { assumeYes: true, tiers: { "test.junction": "green" } });
    const status = result.outcomes[0]?.status;
    expect(status).toBe("deleted");
    expect(await exists(s.junction)).toBe(false);
    expect(await exists(s.target)).toBe(true);
    expect(await readFile(s.canary, "utf8")).toBe(s.content);
  });

  test("a path through a junction into a red directory is refused", async () => {
    const root = await box();
    const red = join(root, "Documents");
    const junction = join(root, "portal");
    const canary = join(red, "canary.txt");
    await mkdir(red, { recursive: true });
    await writeFile(canary, "KEEP");
    await symlink(red, junction, "junction");
    const result = await apply(report([finding(join(junction, "canary.txt"))]), {
      assumeYes: true,
      tiers: { "test.junction": "green" },
    });
    expect(result.outcomes[0]?.status).toBe("failed");
    expect(result.outcomes[0]?.detail).toMatch(/danh sách đỏ|liên kết tượng trưng/);
    expect(await readFile(canary, "utf8")).toBe("KEEP");
  });

  test("a path through a clean junction is still refused", async () => {
    const s = await scene("through");
    const result = await apply(report([finding(join(s.junction, "canary.txt"))]), {
      assumeYes: true,
      tiers: { "test.junction": "green" },
    });
    expect(result.outcomes[0]?.status).toBe("failed");
    expect(result.outcomes[0]?.detail).toMatch(/liên kết tượng trưng/);
    expect(await readFile(s.canary, "utf8")).toBe(s.content);
  });

  test("moveToTrash of a junction leaf leaves the target intact", async () => {
    const s = await scene("trash");
    const result = await moveToTrash(s.junction, join(s.root, "Trash"));
    expect(result.status).toBe("trashed");
    expect(await exists(s.target)).toBe(true);
    expect(await readFile(s.canary, "utf8")).toBe(s.content);
  });

  test("findLargeFiles does not walk through a junction", async () => {
    const s = await scene("walk");
    await writeFile(join(s.target, "big.bin"), Buffer.alloc(4096));
    const found = await findLargeFiles({ roots: [s.root], minSize: 1, limit: 50 });
    expect(found.filter((file) => file.path.startsWith(s.junction + sep))).toEqual([]);
    expect(found.some((file) => file.path === join(s.target, "big.bin"))).toBe(true);
  });
});
