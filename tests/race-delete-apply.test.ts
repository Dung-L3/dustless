import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const home = mkdtempSync(join(tmpdir(), "dustless-q5b2-home-"));
process.env["HOME"] = home;
process.env["XDG_CONFIG_HOME"] = join(home, "config");

const { apply } = await import("../src/core/apply.ts");
const { assertPathDeletable } = await import("../src/mcp/safety.ts");

type Finding = import("../src/types.ts").Finding;
type ScanReport = import("../src/types.ts").ScanReport;

const roots: string[] = [home];

afterAll(async () => {
  for (const root of roots) await rm(root, { recursive: true, force: true });
});

async function box(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "dustless-q5b2-"));
  roots.push(root);
  return root;
}

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

describe("race delete apply", () => {
  test("control: a clean directory is deleted", async () => {
    const root = await box();
    const dir = join(root, "src");
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, "data.txt"), "payload");
    const result = await apply(report([finding(dir)]), { assumeYes: true, tiers: { "test.cache": "green" } });
    expect(result.outcomes[0]?.status).toBe("deleted");
    expect(await exists(dir)).toBe(false);
  });

  test("red swap: symlink into a red directory refuses and keeps payload", async () => {
    const root = await box();
    const src = join(root, "src");
    await mkdir(src, { recursive: true });
    await writeFile(join(src, "data.txt"), "payload");
    const red = join(root, "Documents");
    await mkdir(red, { recursive: true });
    await writeFile(join(red, "keep.txt"), "keep");
    const result = await apply(report([finding(src)]), {
      assumeYes: true,
      tiers: { "test.cache": "green" },
      beforeDelete: async () => {
        await rm(src, { recursive: true, force: true });
        await symlink(red, src);
      },
    });
    expect(result.outcomes[0]?.status).toBe("failed");
    expect(result.outcomes[0]?.detail).toMatch(/danh sách đỏ/);
    expect(await readFile(join(red, "keep.txt"), "utf8")).toBe("keep");
  });

  test("changed swap: symlink to another directory refuses and keeps payload", async () => {
    const root = await box();
    const src = join(root, "src");
    await mkdir(src, { recursive: true });
    await writeFile(join(src, "data.txt"), "payload");
    const other = join(root, "other");
    await mkdir(other, { recursive: true });
    await writeFile(join(other, "data.txt"), "payload");
    const result = await apply(report([finding(src)]), {
      assumeYes: true,
      tiers: { "test.cache": "green" },
      beforeDelete: async () => {
        await rm(src, { recursive: true, force: true });
        await symlink(other, src);
      },
    });
    expect(result.outcomes[0]?.status).toBe("failed");
    expect(result.outcomes[0]?.detail).toMatch(/đường dẫn thay đổi/);
    expect(await readFile(join(other, "data.txt"), "utf8")).toBe("payload");
  });

  test("mcp guard: red symlink throws, clean directory does not", async () => {
    const root = await box();
    const red = join(root, "Documents");
    await mkdir(red, { recursive: true });
    await writeFile(join(red, "keep.txt"), "keep");
    const link = join(root, "link");
    await symlink(red, link);
    expect(() => assertPathDeletable(finding(link))).toThrow(/red blocklist/);
    const clean = join(root, "clean");
    await mkdir(clean, { recursive: true });
    expect(() => assertPathDeletable(finding(clean))).not.toThrow();
  });
});
