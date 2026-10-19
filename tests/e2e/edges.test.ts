import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { chmod, mkdir, stat, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import {
  applyJson,
  BINARY,
  cleanupAll,
  digest,
  measuredFreed,
  MB,
  plant,
  sandbox,
  scanJson,
  treeBytes,
  VERSION,
  userRules,
  type Sandbox,
} from "./harness.ts";

const exists = async (path: string): Promise<boolean> => await stat(path).then(() => true, () => false);

afterAll(cleanupAll);

describe("spaces and non-ASCII in a cache path", () => {
  let box: Sandbox;
  const weird = "hé lô wörld 缓存 🚀";

  beforeAll(async () => {
    box = await sandbox("unicode");
    await plant(join(box.home, ".npm", "_cacache", weird), 3 * MB, 3);
    await userRules(box.home, `- id: test.unicode\n  tier: green\n  desc: unicode\n  paths: { all: "${join(box.home, ".npm", "_cacache", weird)}" }\n`);
  });

  afterAll(async () => {
    await box.dispose();
  });

  test("scan reports the exact byte count for a path with spaces and non-ASCII", async () => {
    const report = scanJson((await box.run(["scan", "--json"])).stdout);
    const hit = report.findings.find((f) => f.ruleId === "test.unicode");
    expect(hit?.bytes).toBe(3 * MB);
    expect(hit?.path).toContain(weird);
    expect(hit?.tier).toBe("green");
  });

  test("apply --yes deletes it without mangling the path", async () => {
    const result = applyJson((await box.run(["apply", "--yes", "--json"])).stdout);
    const outcome = result.outcomes.find((o) => o.ruleId === "test.unicode");
    expect(outcome?.status).toBe("deleted");
    expect(outcome?.path).toContain(weird);
    expect(await exists(join(box.home, ".npm", "_cacache", weird))).toBe(false);
    expect(result.freed).toBe(measuredFreed(result));
  });
});

describe("a symlink inside a scanned directory must not escape the sandbox", () => {
  let box: Sandbox;
  const cache = (): string => join(box.home, ".npm", "_cacache");

  beforeAll(async () => {
    box = await sandbox("symlink");
    await plant(join(cache(), "sub"), 1 * MB, 1);
    await plant(box.outside, 4 * MB, 1);
    await symlink(box.outside, join(cache(), "escape-dir"));
    await symlink(join(box.outside, "blob-0.bin"), join(cache(), "escape-file"));
  });

  afterAll(async () => {
    await box.dispose();
  });

  test("the walk does not follow symlinks out of the scanned tree", async () => {
    const report = scanJson((await box.run(["scan", "--json"])).stdout);
    const hit = report.findings.find((f) => f.ruleId === "npm.cacache");
    expect(hit?.bytes).toBe(1 * MB);
  });

  test("apply --yes deletes the symlinks but never the data behind them", async () => {
    const before = await digest(box.outside);
    expect(await treeBytes(box.outside)).toBe(4 * MB);
    const run = await box.run(["apply", "--yes", "--json"]);
    expect(run.code).toBe(0);
    expect(applyJson(run.stdout).outcomes[0]?.status).toBe("deleted");
    expect(await digest(box.outside)).toBe(before);
    expect(await treeBytes(box.outside)).toBe(4 * MB);
  });
});

describe("a symlinked cache root must not be deleted through", () => {
  let box: Sandbox;

  beforeAll(async () => {
    box = await sandbox("symroot");
    await plant(box.outside, 4 * MB, 1);
    await mkdir(join(box.home, ".npm"), { recursive: true });
    await symlink(box.outside, join(box.home, ".npm", "_cacache"));
  });

  afterAll(async () => {
    await box.dispose();
  });

  test("apply --yes removes the link but never the directory it points at", async () => {
    const before = await digest(box.outside);
    const run = await box.run(["apply", "--yes", "--json"]);
    expect(run.code).toBe(0);
    expect(applyJson(run.stdout).outcomes[0]?.status).toBe("deleted");
    expect(await digest(box.outside)).toBe(before);
    expect(await treeBytes(box.outside)).toBe(4 * MB);
    expect(await Bun.$`test -e ${box.outside}`.quiet().nothrow().then((r) => r.exitCode)).toBe(0);
  });
});

describe("a wildcard cache rule must not delete through a leaf symlink", () => {
  let box: Sandbox;
  const cacheDir = (): string => join(box.home, ".cache");

  beforeAll(async () => {
    box = await sandbox("wildsym");
    await mkdir(cacheDir(), { recursive: true });
    await plant(box.outside, 4 * MB, 1);
    await symlink(box.outside, join(cacheDir(), "entry"));
    await userRules(box.home, `- id: test.wild\n  tier: green\n  desc: wild\n  paths: { all: "${cacheDir()}/*" }\n  recoveryLabel: download\n`);
  });

  afterAll(async () => {
    await box.dispose();
  });

  test("scan reports the link itself, without a trailing separator", async () => {
    const report = scanJson((await box.run(["scan", "--json"])).stdout);
    const hit = report.findings.find((f) => f.ruleId === "test.wild");
    expect(hit?.path).toBe(join(cacheDir(), "entry"));
  });

  test("apply removes the link and leaves the target intact", async () => {
    const before = await digest(box.outside);
    const run = await box.run(["apply", "--yes", "--json"]);
    expect(run.code).toBe(0);
    const outcome = applyJson(run.stdout).outcomes.find((o) => o.ruleId === "test.wild");
    expect(outcome?.status).toBe("deleted");
    expect(await digest(box.outside)).toBe(before);
    expect(await treeBytes(box.outside)).toBe(4 * MB);
    expect(await exists(join(cacheDir(), "entry"))).toBe(false);
  });
});

describe("a read-only cache directory", () => {
  let box: Sandbox;
  const locked = (): string => join(box.home, ".npm", "_cacache", "locked");

  beforeAll(async () => {
    box = await sandbox("readonly");
    await plant(locked(), 512 * 1024, 1);
    await chmod(locked(), 0o500);
  });

  afterAll(async () => {
    await box.dispose();
  });

  test("scan still measures it without crashing", async () => {
    const run = await box.run(["scan", "--json"]);
    expect(run.code).toBe(0);
    expect(scanJson(run.stdout).findings[0]?.bytes).toBe(512 * 1024);
  });

  test("apply reports a failure with the errno instead of hanging or crashing", async () => {
    const run = await box.run(["apply", "--yes", "--json"]);
    expect(run.code).toBe(1);
    const outcome = applyJson(run.stdout).outcomes[0];
    expect(outcome?.status).toBe("failed");
    expect(outcome?.detail).toMatch(/EACCES|EPERM|ENOTEMPTY/);
    expect(await treeBytes(locked())).toBe(512 * 1024);
  });

  afterAll(async () => {
    await chmod(locked(), 0o700).catch(() => undefined);
  });
});

describe("a zero-byte cache directory", () => {
  let box: Sandbox;

  beforeAll(async () => {
    box = await sandbox("zero");
    await mkdir(join(box.home, ".npm", "_cacache"), { recursive: true });
    await mkdir(join(box.home, ".bun", "install", "cache"), { recursive: true });
  });

  afterAll(async () => {
    await box.dispose();
  });

  test("scan reports no findings and exits 0", async () => {
    const run = await box.run(["scan", "--json"]);
    expect(run.code).toBe(0);
    const report = scanJson(run.stdout);
    expect(report.findings).toEqual([]);
    expect(report.reclaimable).toBe(0);
  });

  test("apply is a clean no-op and leaves the empty dirs in place", async () => {
    const run = await box.run(["apply", "--yes"]);
    expect(run.code).toBe(0);
    expect(run.stderr).toBe("");
    expect(run.stdout).toContain("Không có mục nào đủ điều kiện xóa");
    for (const dir of [".npm/_cacache", ".bun/install/cache"]) {
      expect(await Bun.$`test -d ${join(box.home, dir)}`.quiet().nothrow().then((r) => r.exitCode)).toBe(0);
    }
  });
});

describe("a very deep directory tree", () => {
  let box: Sandbox;
  const depth = 50;

  beforeAll(async () => {
    box = await sandbox("deep");
    let path = join(box.home, ".bun", "install", "cache");
    for (let i = 0; i < depth; i++) path = join(path, `l${i}`);
    await mkdir(path, { recursive: true });
    await writeFile(join(path, "deep.bin"), Buffer.alloc(256 * 1024, 7));
  });

  afterAll(async () => {
    await box.dispose();
  });

  test("scan walks 50 levels without stack overflow", async () => {
    const run = await box.run(["scan", "--json"]);
    expect(run.code).toBe(0);
    expect(run.stderr).toBe("");
    expect(scanJson(run.stdout).findings[0]?.bytes).toBe(256 * 1024);
  });

  test("apply deletes the deep tree cleanly", async () => {
    const run = await box.run(["apply", "--yes", "--json"]);
    expect(run.code).toBe(0);
    expect(applyJson(run.stdout).outcomes[0]?.status).toBe("deleted");
    expect(await treeBytes(join(box.home, ".bun", "install", "cache"))).toBe(0);
  });
});

describe("two concurrent scans", () => {
  let box: Sandbox;

  beforeAll(async () => {
    box = await sandbox("concurrent");
    await plant(join(box.home, ".npm", "_cacache"), 1 * MB, 2);
    await plant(join(box.home, ".bun", "install", "cache"), 1 * MB, 2);
  });

  afterAll(async () => {
    await box.dispose();
  });

  test("all of them exit 0 and agree byte-for-byte", async () => {
    const runs = await Promise.all([box.run(["scan", "--json"]), box.run(["scan", "--json"]), box.run(["scan", "--json"])]);
    for (const run of runs) {
      expect(run.code).toBe(0);
      expect(run.stderr).toBe("");
      const report = scanJson(run.stdout);
      expect(report.findings.length).toBe(2);
      expect(report.reclaimable).toBe(2 * MB);
    }
    const [first, second, third] = runs.map((r) => scanJson(r.stdout));
    const shape = (r: { findings: { ruleId: string; bytes: number }[] }): string =>
      JSON.stringify(r.findings.map((f) => [f.ruleId, f.bytes]).sort());
    expect(shape(second as never)).toBe(shape(first as never));
    expect(shape(third as never)).toBe(shape(first as never));
  });

  test("a concurrent scan while another deletes still exits 0", async () => {
    const results = await Promise.all([box.run(["scan", "--json"]), box.run(["apply", "--yes", "--json"])]);
    for (const run of results) {
      expect(run.code).toBe(0);
      expect(() => JSON.parse(run.stdout)).not.toThrow();
    }
  });
});

describe("the sandbox itself is never violated", () => {
  test("every path the CLI touches is inside the sandbox", async () => {
    const box = await sandbox("containment");
    await plant(join(box.home, ".npm", "_cacache"), 1 * MB, 1);
    const report = scanJson((await box.run(["scan", "--json"])).stdout);
    for (const finding of report.findings) expect(finding.path.startsWith(box.home)).toBe(true);
    const applied = applyJson((await box.run(["apply", "--yes", "--json"])).stdout);
    for (const outcome of applied.outcomes) expect(outcome.path.startsWith(box.home)).toBe(true);
    await box.dispose();
  });

  test("the harness refuses to pass an out-of-sandbox path to the binary", async () => {
    const box = await sandbox("outside-guard");
    expect(() => box.run(["scan", "/Users/mac"])).toThrow(/out-of-sandbox/);
    expect(() => box.run(["apply", "--yes", "/Users/mac/Documents"])).toThrow(/out-of-sandbox/);
    expect(() => box.run(["scan", box.outside])).toThrow(/out-of-sandbox/);
    await box.dispose();
  });

  test("HOME is the sandbox for every command the CLI runs", async () => {
    const box = await sandbox("home-check");
    await plant(join(box.home, ".npm", "_cacache"), 1 * MB, 1);
    const doctor = JSON.parse((await box.run(["doctor", "--json"])).stdout) as { home: string };
    expect(doctor.home).toBe(box.home);
    expect(doctor.home.startsWith("/Users/mac")).toBe(false);
    const listed = JSON.parse((await box.run(["rule", "list", "--json"])).stdout) as { paths: Record<string, string> }[];
    for (const rule of listed) {
      for (const pattern of Object.values(rule.paths).flat()) {
        if (typeof pattern !== "string" || !pattern.startsWith("~")) continue;
        expect(pattern).not.toContain("/Users/mac");
      }
    }
    await box.dispose();
  });

  test("the compiled binary is what actually runs", async () => {
    const box = await sandbox("binary");
    const direct = await box.run(["version"], { cwd: "/" });
    expect(direct.code).toBe(0);
    expect(direct.stdout.trim()).toBe(VERSION);
    expect(BINARY).toContain(join("dist", "dustless"));
    await box.dispose();
  });
});