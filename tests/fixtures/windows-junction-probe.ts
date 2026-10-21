import assert from "node:assert/strict";
import { lstat, mkdir, mkdtemp, readFile, symlink, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join, resolve, sep } from "node:path";
import { apply } from "../../src/core/apply.ts";
import { moveToTrash } from "../../src/core/apps/index.ts";
import { findLargeFiles } from "../../src/core/largefiles/index.ts";
import type { Finding, ScanReport } from "../../src/types.ts";
import { SCHEMA_VERSION } from "../../src/types.ts";

const scenario = process.argv[2];
const home = resolve(homedir());

assert.equal(process.platform, "win32");
assert.equal(home.toLowerCase(), resolve(process.env["HOME"] ?? "").toLowerCase());
assert.equal(home.toLowerCase(), resolve(process.env["USERPROFILE"] ?? "").toLowerCase());

const exists = async (path: string): Promise<boolean> => await lstat(path).then(() => true, () => false);

async function root(): Promise<string> {
  return await mkdtemp(join(home, "case-"));
}

function finding(path: string): Finding {
  return {
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
    note: [],
  };
}

function report(findings: Finding[]): ScanReport {
  return {
    schemaVersion: SCHEMA_VERSION,
    findings,
    totals: {
      green: { count: 0, bytes: 0 },
      yellow: { count: 0, bytes: 0 },
      red: { count: 0, bytes: 0 },
      blocked: { count: 0, bytes: 0 },
    },
    reclaimable: 0,
    freeBefore: 0,
    platform: "win",
    scannedMs: 0,
    unscannable: [],
    unscannableSummary: { absent: 0, no_access: 0, not_supported: 0, error: 0, red: 0 },
  };
}

async function scene(label: string): Promise<{ root: string; target: string; junction: string; canary: string; content: string }> {
  const box = await root();
  const target = join(box, `target-${label}`);
  const junction = join(box, `cache-${label}`);
  const canary = join(target, "canary.txt");
  const content = `JUNCTION-CANARY-${label}-${Date.now()}`;
  await mkdir(target, { recursive: true });
  await writeFile(canary, content);
  await symlink(target, junction, "junction");
  return { root: box, target, junction, canary, content };
}

async function applyOne(path: string) {
  const result = await apply(report([finding(path)]), {
    assumeYes: true,
    tiers: { "test.junction": "green" },
  });
  assert.equal(result.outcomes.length, 1);
  return result.outcomes[0]!;
}

switch (scenario) {
  case "leaf": {
    const s = await scene("leaf");
    const outcome = await applyOne(s.junction);
    assert.equal(outcome.status, "deleted");
    assert.equal(await exists(s.junction), false);
    assert.equal(await exists(s.target), true);
    assert.equal(await readFile(s.canary, "utf8"), s.content);
    break;
  }
  case "red": {
    const box = await root();
    const red = join(box, "Documents");
    const junction = join(box, "portal");
    const canary = join(red, "canary.txt");
    await mkdir(red, { recursive: true });
    await writeFile(canary, "KEEP");
    await symlink(red, junction, "junction");
    const outcome = await applyOne(join(junction, "canary.txt"));
    assert.equal(outcome.status, "failed");
    assert.equal(outcome.detail, "từ chối: nằm trong danh sách đỏ");
    assert.equal(await exists(junction), true);
    assert.equal(await readFile(canary, "utf8"), "KEEP");
    break;
  }
  case "through": {
    const s = await scene("through");
    const outcome = await applyOne(join(s.junction, "canary.txt"));
    assert.equal(outcome.status, "failed");
    assert.equal(outcome.detail, "từ chối: đường dẫn đi qua liên kết tượng trưng");
    assert.equal(await exists(s.junction), true);
    assert.equal(await readFile(s.canary, "utf8"), s.content);
    break;
  }
  case "trash": {
    const s = await scene("trash");
    const trash = join(s.root, "Trash");
    const moved = join(trash, basename(s.junction));
    const result = await moveToTrash(s.junction, trash);
    assert.equal(result.status, "trashed");
    assert.equal(await exists(s.junction), false);
    assert.equal(await exists(moved), true);
    assert.equal((await lstat(moved)).isSymbolicLink(), true);
    assert.equal(await exists(s.target), true);
    assert.equal(await readFile(s.canary, "utf8"), s.content);
    break;
  }
  case "walk": {
    const s = await scene("walk");
    const direct = join(s.target, "big.bin");
    await writeFile(direct, Buffer.alloc(4096));
    const found = await findLargeFiles({ roots: [s.root], minSize: 1, limit: 50 });
    assert.equal(found.filter((file) => file.path === direct).length, 1);
    assert.deepEqual(found.filter((file) => file.path.startsWith(s.junction + sep)), []);
    break;
  }
  default:
    throw new Error(`unknown scenario: ${scenario ?? "<missing>"}`);
}

console.log("ok");
