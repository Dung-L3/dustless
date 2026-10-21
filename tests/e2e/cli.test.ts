import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdir, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import {
  age,
  applyJson,
  assertTempRoot,
  BINARY,
  cleanupAll,
  digest,
  ensureBinary,
  gradleWrapper,
  measuredFreed,
  MB,
  plant,
  REPO,
  sandbox,
  scanJson,
  currentPlatform,
  treeBytes,
  VERSION,
  type Sandbox,
} from "./harness.ts";

const built = await ensureBinary();

const exists = async (path: string): Promise<boolean> => await stat(path).then(() => true, () => false);
const at = (path: string, tail: string): boolean => path.replaceAll("\\", "/").endsWith(tail);

afterAll(cleanupAll);

describe("1. fresh install", () => {
  let box: Sandbox;
  beforeAll(async () => {
    box = await sandbox("install");
  });
  afterAll(async () => {
    await box.dispose();
  });

  test("build succeeds and yields an executable binary", async () => {
    expect(built.exitCode).toBe(0);
    expect(await Bun.$`test -x ${BINARY}`.cwd(REPO).quiet().nothrow().then((r) => r.exitCode)).toBe(0);
  });

  test("--version and version both print 0.1.0 and exit 0", async () => {
    const flag = await box.run(["--version"]);
    const word = await box.run(["version"]);
    expect(flag.code).toBe(0);
    expect(word.code).toBe(0);
    expect(word.stdout.trim()).toBe(VERSION);
    expect(flag.stdout).toContain(VERSION);
  });

  test("version --json emits parseable JSON carrying the version", async () => {
    const run = await box.run(["version", "--json"]);
    expect(run.code).toBe(0);
    expect(JSON.parse(run.stdout)).toEqual({ version: VERSION });
  });

  test("works from an absolute path with an unrelated cwd", async () => {
    const run = await box.run(["version"], { cwd: "/" });
    expect(run.code).toBe(0);
    expect(run.stdout.trim()).toBe(VERSION);
  });
});

describe("2. scan on an empty sandbox", () => {
  let box: Sandbox;
  beforeAll(async () => {
    box = await sandbox("empty");
  });
  afterAll(async () => {
    await box.dispose();
  });

  test("finds nothing, exits 0, reclaimable 0", async () => {
    const run = await box.run(["scan", "--json"]);
    expect(run.code).toBe(0);
    const report = scanJson(run.stdout);
    expect(report.findings).toEqual([]);
    expect(report.reclaimable).toBe(0);
    expect(report.totals["green"]).toEqual({ count: 0, bytes: 0 });
    expect(report.totals["blocked"]).toEqual({ count: 0, bytes: 0 });
    expect(report.platform).toBe(currentPlatform());
    expect(report.freeBefore).toBeGreaterThan(0);
  });

  test("human scan and apply both no-op cleanly", async () => {
    const scan = await box.run(["scan"]);
    expect(scan.code).toBe(0);
    expect(scan.stdout).toContain("Không có gì để dọn");
    const apply = await box.run(["apply", "--yes"]);
    expect(apply.code).toBe(0);
    expect(apply.stdout).toContain("Không có mục nào đủ điều kiện xóa");
  });
});

describe("3. scan finds planted caches with exact byte accounting", () => {
  let box: Sandbox;
  beforeAll(async () => {
    box = await sandbox("planted");
    await plant(join(box.home, ".npm", "_cacache"), 5 * MB, 5);
    await plant(join(box.home, ".bun", "install", "cache"), 3 * MB, 3);
  });
  afterAll(async () => {
    await box.dispose();
  });

  test("each cache is reported at its exact planted size and tier green", async () => {
    const report = scanJson((await box.run(["scan", "--json"])).stdout);
    const npm = report.findings.find((f) => f.ruleId === "npm.cacache");
    const bun = report.findings.find((f) => f.ruleId === "bun.cache");
    expect(npm?.bytes).toBe(5 * MB);
    expect(bun?.bytes).toBe(3 * MB);
    expect(npm?.tier).toBe("green");
    expect(bun?.tier).toBe("green");
    expect(npm?.blocked).toBe(false);
    expect(bun?.verified).toBe(true);
  });

  test("reclaimable is the exact sum, and the tree really holds that many bytes", async () => {
    const report = scanJson((await box.run(["scan", "--json"])).stdout);
    expect(report.reclaimable).toBe(8 * MB);
    expect(report.totals["green"]?.bytes).toBe(8 * MB);
    expect(await treeBytes(join(box.home, ".npm", "_cacache"))).toBe(5 * MB);
    expect(await treeBytes(join(box.home, ".bun", "install", "cache"))).toBe(3 * MB);
  });

  test("human scan lists both rules with a green summary", async () => {
    const run = await box.run(["scan"]);
    expect(run.code).toBe(0);
    expect(run.stdout).toContain("npm.cacache");
    expect(run.stdout).toContain("bun.cache");
    expect(run.stdout).toContain("8.0 MB");
  });
});

describe("4. cross-verification blocks a gradle cache a project still uses", () => {
  let box: Sandbox;
  const used = (): string => join(box.home, ".gradle", "caches", "8.14");
  const spare = (): string => join(box.home, ".gradle", "caches", "8.12");

  beforeAll(async () => {
    box = await sandbox("gradle-block");
    const project = join(box.home, "work", "api", "android");
    await mkdir(join(project, "gradle", "wrapper"), { recursive: true });
    await writeFile(join(project, "settings.gradle"), 'rootProject.name = "api"\n');
    await gradleWrapper(join(project, "gradle", "wrapper", "gradle-wrapper.properties"), "8.14");
    await plant(used(), 2 * MB, 2);
    await plant(spare(), 1 * MB, 1);
    await age(join(box.home, ".gradle", "caches"), 200);
  });

  afterAll(async () => {
    await box.dispose();
  });

  test("the pinned cache is BLOCKED and yellow, never green", async () => {
    const report = scanJson((await box.run(["scan", "--json"])).stdout);
    const hit = report.findings.find((f) => at(f.path, "/.gradle/caches/8.14"));
    expect(hit?.blocked).toBe(true);
    expect(hit?.verified).toBe(false);
    expect(hit?.tier).toBe("yellow");
    expect(hit?.note?.[0]?.code).toBe("verify_failed");
    expect(hit?.note?.[0]?.params?.["cause"]).toBe("gradle_used");
    expect(report.totals["blocked"]).toEqual({ count: 1, bytes: 2 * MB });
  });

  test("the block cannot be explained by age: the cache is older than minAgeDays", async () => {
    const report = scanJson((await box.run(["scan", "--json"])).stdout);
    const hit = report.findings.find((f) => at(f.path, "/.gradle/caches/8.14"));
    expect(hit?.ageDays ?? 0).toBeGreaterThan(30);
    expect(hit?.note?.[0]?.code).not.toBe("min_age");
    expect(report.findings.find((f) => at(f.path, "/.gradle/caches/8.12"))?.tier).toBe("green");
  });

  test("apply --yes leaves the blocked cache byte-for-byte intact and deletes only the spare", async () => {
    const before = await digest(used());
    const run = await box.run(["apply", "--yes", "--json"]);
    expect(run.code).toBe(0);
    const result = applyJson(run.stdout);
    expect(result.outcomes.find((o) => at(o.path, "/.gradle/caches/8.14"))?.status).toBe("skipped");
    expect(result.outcomes.find((o) => at(o.path, "/.gradle/caches/8.14"))?.detail?.code).toBe("verify_failed");
    expect(await digest(used())).toBe(before);
    expect(await treeBytes(used())).toBe(2 * MB);
    expect(result.outcomes.find((o) => at(o.path, "/.gradle/caches/8.12"))?.status).toBe("deleted");
    expect(await exists(spare())).toBe(false);
  });

  test("only the spare is counted as reclaimable; the blocked cache is not", async () => {
    const report = scanJson((await box.run(["scan", "--json"])).stdout);
    expect(report.reclaimable).toBe(0);
    expect(report.totals["blocked"]).toEqual({ count: 1, bytes: 2 * MB });
  });
});

describe("5. vendored copies do not pin a gradle version", () => {
  let box: Sandbox;

  beforeAll(async () => {
    box = await sandbox("vendored");
    const project = join(box.home, "work", "api", "android");
    await mkdir(join(project, "gradle", "wrapper"), { recursive: true });
    await writeFile(join(project, "settings.gradle"), 'rootProject.name = "api"\n');
    await gradleWrapper(join(project, "gradle", "wrapper", "gradle-wrapper.properties"), "8.14");
    const vendored = join(project, "build", "ios", "SourcePackages", "firebase", "example", "android");
    await mkdir(join(vendored, "gradle", "wrapper"), { recursive: true });
    await gradleWrapper(join(vendored, "gradle", "wrapper", "gradle-wrapper.properties"), "8.12");
    for (const version of ["8.12", "8.14"]) await plant(join(box.home, ".gradle", "caches", version), 1 * MB, 1);
    await age(join(box.home, ".gradle", "caches"), 200);
  });

  afterAll(async () => {
    await box.dispose();
  });

  test("the vendored 8.12 reference does not keep the 8.12 cache alive", async () => {
    const report = scanJson((await box.run(["scan", "--json"])).stdout);
    const hit = report.findings.find((f) => at(f.path, "/.gradle/caches/8.12"));
    expect(hit?.blocked).toBe(false);
    expect(hit?.verified).toBe(true);
    expect(hit?.tier).toBe("green");
  });

  test("the real 8.14 project still holds the 8.14 cache", async () => {
    const report = scanJson((await box.run(["scan", "--json"])).stdout);
    const hit = report.findings.find((f) => at(f.path, "/.gradle/caches/8.14"));
    expect(hit?.blocked).toBe(true);
    expect(hit?.note?.[0]?.params?.["version"]).toBe("8.14");
  });

  test("apply --yes deletes only the genuinely unused cache", async () => {
    const before = await digest(join(box.home, ".gradle", "caches", "8.14"));
    const result = applyJson((await box.run(["apply", "--yes", "--json"])).stdout);
    expect(result.outcomes.find((o) => at(o.path, "/.gradle/caches/8.12"))?.status).toBe("deleted");
    expect(result.outcomes.find((o) => at(o.path, "/.gradle/caches/8.14"))?.status).toBe("skipped");
    expect(await digest(join(box.home, ".gradle", "caches", "8.14"))).toBe(before);
    expect(await exists(join(box.home, ".gradle", "caches", "8.12"))).toBe(false);
  });
});

describe("6. apply requires confirmation", () => {
  let box: Sandbox;
  beforeAll(async () => {
    box = await sandbox("confirm");
    await plant(join(box.home, ".npm", "_cacache"), 2 * MB, 2);
  });
  afterAll(async () => {
    await box.dispose();
  });

  test("with no TTY and no --yes, nothing is deleted and exit is 0", async () => {
    const before = await digest(join(box.home, ".npm", "_cacache"));
    const run = await box.run(["apply"]);
    expect(run.code).toBe(0);
    expect(run.stdout).toContain("Sẽ xóa");
    expect(run.stdout).toContain("Đã hủy. Không có gì bị xóa");
    expect(run.stdout.indexOf("Sẽ xóa")).toBeLessThan(run.stdout.indexOf("Đã hủy"));
    expect(await digest(join(box.home, ".npm", "_cacache"))).toBe(before);
    expect(await treeBytes(join(box.home, ".npm", "_cacache"))).toBe(2 * MB);
  });

  test("answering anything but y on a TTY also cancels", async () => {
    const before = await digest(join(box.home, ".npm", "_cacache"));
    assertTempRoot(box.home);
    const child = Bun.spawn([BINARY, "apply"], {
      env: { PATH: "/usr/bin:/bin", HOME: box.home, NO_COLOR: "1" },
      stdin: new TextEncoder().encode("n\n"),
      stdout: "pipe",
      stderr: "pipe",
      cwd: "/",
    });
    const code = await child.exited;
    expect(code).toBe(0);
    expect(await digest(join(box.home, ".npm", "_cacache"))).toBe(before);
  });
});

describe("7. apply --yes deletes and reports real freed bytes", () => {
  let box: Sandbox;
  const planted = 48 * MB;
  beforeAll(async () => {
    box = await sandbox("freed");
    await plant(join(box.home, ".npm", "_cacache"), planted, 6);
  });
  afterAll(async () => {
    await box.dispose();
  });

  test("deletes the cache and reports freed bytes measured off the disk, not the estimate", async () => {
    expect(scanJson((await box.run(["scan", "--json"])).stdout).findings.length).toBe(1);
    const run = await box.run(["apply", "--yes", "--json"]);
    expect(run.code).toBe(0);
    const result = applyJson(run.stdout);
    expect(result.outcomes).toHaveLength(1);
    expect(result.outcomes[0]?.status).toBe("deleted");
    expect(result.outcomes[0]?.bytes).toBe(planted);
    expect(await exists(join(box.home, ".npm", "_cacache"))).toBe(false);
    expect(result.freed).toBe(measuredFreed(result));
  });

  test("freeBefore and freeAfter are both real free-space readings after a real deletion", async () => {
    const fresh = await sandbox("freed-check");
    await plant(join(fresh.home, ".bun", "install", "cache"), 32 * MB, 4);
    const result = applyJson((await fresh.run(["apply", "--yes", "--json"])).stdout);
    expect(result.outcomes[0]?.status).toBe("deleted");
    expect(await exists(join(fresh.home, ".bun", "install", "cache"))).toBe(false);
    expect(result.freeBefore).toBeGreaterThan(0);
    expect(result.freeAfter).toBeGreaterThan(0);
    expect(result.freed).toBe(measuredFreed(result));
    await fresh.dispose();
  });
});
