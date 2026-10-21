import { afterAll, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, stat, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import type { Finding, ScanReport } from "../src/types.ts";
import { apply } from "../src/core/apply.ts";
import { userRulesPath } from "../src/core/rules.ts";
import { accountedBytes, adjustScanAccounting } from "../src/core/space.ts";

const DAY = 86_400_000;
const sandbox = await mkdtemp(join(tmpdir(), "dustless-apply-safety-"));
const originalXdg = process.env["XDG_CONFIG_HOME"];
process.env["XDG_CONFIG_HOME"] = join(sandbox, "config");

const exists = async (path: string): Promise<boolean> => await stat(path).then(() => true, () => false);

const finding = (path: string, overrides: Partial<Finding> = {}): Finding => ({
  ruleId: "test.cache",
  tier: "green",
  desc: "x",
  path,
  bytes: 1024,
  mtime: 0,
  atime: 0,
  ageDays: 999,
  verified: true,
  blocked: false,
  note: "",
  ...overrides,
});

const report = (findings: Finding[]): ScanReport => ({
  findings,
  totals: { green: { count: 0, bytes: 0 }, yellow: { count: 0, bytes: 0 }, red: { count: 0, bytes: 0 }, blocked: { count: 0, bytes: 0 } },
  reclaimable: 0,
  freeBefore: 0,
  platform: "mac",
  scannedMs: 0,
  unscannable: [],
  unscannableSummary: { absent: 0, no_access: 0, not_supported: 0, error: 0, red: 0 },
});

const writeRules = async (body: string): Promise<void> => {
  await mkdir(dirname(userRulesPath()), { recursive: true });
  await writeFile(userRulesPath(), body);
};

const fakePs = async (listing: string[], tasklist = false): Promise<{ restore: () => void; argv: string }> => {
  const bin = join(sandbox, `bin-${listing.join("").replace(/\W/g, "").slice(0, 24)}`);
  await mkdir(bin, { recursive: true });
  const ps = listing.map((line) => `echo ${JSON.stringify(line)}`).join("\n");
  await writeFile(join(bin, "ps"), `#!/bin/sh\necho "$@" > "$(dirname "$0")/ps-argv.txt"\n${ps}\nexit ${listing.length > 0 ? 0 : 1}\n`);
  await chmod(join(bin, "ps"), 0o755);
  await writeFile(join(bin, "tasklist"), `#!/bin/sh\nexit ${tasklist ? 0 : 1}\n`);
  await chmod(join(bin, "tasklist"), 0o755);
  const prior = process.env["PATH"];
  process.env["PATH"] = `${bin}:${prior ?? ""}`;
  return {
    argv: join(bin, "ps-argv.txt"),
    restore: () => {
      if (prior === undefined) delete process.env["PATH"];
      else process.env["PATH"] = prior;
    },
  };
};

const fakeNoListing = async (): Promise<{ restore: () => void }> => {
  const empty = join(sandbox, "bin-empty");
  await mkdir(empty, { recursive: true });
  const prior = process.env["PATH"];
  process.env["PATH"] = empty;
  return {
    restore: () => {
      if (prior === undefined) delete process.env["PATH"];
      else process.env["PATH"] = prior;
    },
  };
};

afterAll(async () => {
  if (originalXdg === undefined) delete process.env["XDG_CONFIG_HOME"];
  else process.env["XDG_CONFIG_HOME"] = originalXdg;
  execFileSync("chmod", ["-R", "u+rwX", sandbox], { stdio: "ignore" });
  await rm(sandbox, { recursive: true, force: true });
});

describe("the delete path re-verifies the finding", () => {
  test("a cache touched after the scan is not deleted and the payload survives", async () => {
    const dir = join(sandbox, "touched-cache");
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, "blob.bin"), "payload");
    const scanned = Date.now() - 40 * DAY;
    await utimes(join(dir, "blob.bin"), new Date(scanned), new Date(scanned));
    await utimes(dir, new Date(scanned), new Date(scanned));
    await writeRules(
      `- id: test.cache\n  tier: green\n  desc: cache\n  paths: { all: ${JSON.stringify(dir)} }\n  minAgeDays: 30\n`,
    );
    const touched = new Date();
    await utimes(join(dir, "blob.bin"), touched, touched);

    const result = await apply(report([finding(dir, { mtime: scanned, ageDays: 40 })]), {
      assumeYes: true,
      tiers: { "test.cache": "green" },
    });

    expect(result.outcomes[0]?.status).toBe("skipped");
    expect(result.outcomes[0]?.detail).toMatch(/chạm sau lúc quét/);
    expect(await exists(join(dir, "blob.bin"))).toBe(true);
  });

  test("a cache that was not touched since the scan is still deleted", async () => {
    const dir = join(sandbox, "untouched-cache");
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, "blob.bin"), "payload");
    const scanned = Date.now() - 40 * DAY;
    await utimes(join(dir, "blob.bin"), new Date(scanned), new Date(scanned));
    await utimes(dir, new Date(scanned), new Date(scanned));
    await writeRules(
      `- id: test.cache\n  tier: green\n  desc: cache\n  paths: { all: ${JSON.stringify(dir)} }\n  minAgeDays: 30\n`,
    );

    const result = await apply(report([finding(dir, { mtime: scanned, ageDays: 40 })]), {
      assumeYes: true,
      tiers: { "test.cache": "green" },
    });

    expect(result.outcomes[0]?.status).toBe("deleted");
    expect(await exists(dir)).toBe(false);
  });

  test("a project that became dirty after the scan is not deleted", async () => {
    const repo = join(sandbox, "repo");
    await mkdir(repo, { recursive: true });
    const git = (args: string[]): void => {
      execFileSync("git", args, { cwd: repo, stdio: "ignore" });
    };
    git(["init", "-q"]);
    git(["config", "user.email", "dustless@test.local"]);
    git(["config", "user.name", "dustless"]);
    git(["config", "commit.gpgsign", "false"]);
    const build = join(repo, "build");
    await mkdir(build, { recursive: true });
    await writeFile(join(build, "blob.bin"), "payload");
    git(["add", "-A"]);
    git(["commit", "-q", "-m", "init"]);
    await writeRules(
      `- id: test.cache\n  tier: green\n  desc: cache\n  paths: { all: ${JSON.stringify(build)} }\n  requireVerify: git_clean\n`,
    );

    const clean = await apply(report([finding(build)]), { assumeYes: true, tiers: { "test.cache": "green" } });
    expect(clean.outcomes[0]?.status).toBe("deleted");

    const dirtyRepo = join(sandbox, "dirty-repo");
    await mkdir(dirtyRepo, { recursive: true });
    const dirtyGit = (args: string[]): void => {
      execFileSync("git", args, { cwd: dirtyRepo, stdio: "ignore" });
    };
    dirtyGit(["init", "-q"]);
    dirtyGit(["config", "user.email", "dustless@test.local"]);
    dirtyGit(["config", "user.name", "dustless"]);
    dirtyGit(["config", "commit.gpgsign", "false"]);
    const dirtyBuild = join(dirtyRepo, "build");
    await mkdir(dirtyBuild, { recursive: true });
    await writeFile(join(dirtyBuild, "blob.bin"), "payload");
    dirtyGit(["add", "-A"]);
    dirtyGit(["commit", "-q", "-m", "init"]);
    await writeFile(join(dirtyRepo, "scratch.txt"), "uncommitted\n");

    const dirty = await apply(report([finding(dirtyBuild)]), { assumeYes: true, tiers: { "test.cache": "green" } });
    expect(dirty.outcomes[0]?.status).toBe("skipped");
    expect(dirty.outcomes[0]?.detail).toMatch(/git/);
    expect(await exists(join(dirtyBuild, "blob.bin"))).toBe(true);
  });
});

describe("the busy-process gate matches the real process names", () => {
  test.skipIf(process.platform === "win32")("an npm run in the process table skips the npm cache rule", async () => {
    const dir = join(sandbox, "npm-cache");
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, "blob.bin"), "payload");
    await writeRules(
      `- id: test.npm\n  tier: green\n  desc: npm\n  paths: { all: ${JSON.stringify(dir)} }\n  nativeCommand: npm cache verify\n`,
    );
    const seam = await fakePs(["npm run build"]);
    try {
      const result = await apply(report([finding(dir, { ruleId: "test.npm" })]), {
        assumeYes: true,
        tiers: { "test.npm": "green" },
      });
      expect(result.outcomes[0]?.status).toBe("skipped");
      expect(result.outcomes[0]?.detail).toMatch(/đang chạy/);
      expect(await exists(join(dir, "blob.bin"))).toBe(true);
      const argv = await readFile(seam.argv, "utf8");
      expect(argv).toContain("args=");
      expect(argv).not.toContain("comm=");
    } finally {
      seam.restore();
    }
  });

  test.skipIf(process.platform === "win32")("a bare node process does not block the npm cache rule", async () => {
    const dir = join(sandbox, "npm-cache-free");
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, "blob.bin"), "payload");
    await writeRules(
      `- id: test.npm\n  tier: green\n  desc: npm\n  paths: { all: ${JSON.stringify(dir)} }\n  nativeCommand: npm cache verify\n`,
    );
    const seam = await fakePs(["node /usr/local/bin/node"]);
    try {
      const result = await apply(report([finding(dir, { ruleId: "test.npm" })]), {
        assumeYes: true,
        tiers: { "test.npm": "green" },
      });
      expect(result.outcomes[0]?.status).toBe("deleted");
    } finally {
      seam.restore();
    }
  });

  test.skipIf(process.platform === "win32")("the gradle daemon under java blocks the gradle cache rule", async () => {
    const dir = join(sandbox, "gradle-cache");
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, "blob.bin"), "payload");
    await writeRules(
      `- id: test.gradle\n  tier: green\n  desc: gradle\n  paths: { all: ${JSON.stringify(dir)} }\n  nativeCommand: gradle --stop\n`,
    );
    const seam = await fakePs([
      "/usr/bin/java -classpath /Users/me/.gradle/wrapper/dists/gradle-8.7-bin/abc/gradle-wrapper.jar org.gradle.launcher.GradleMain build",
    ]);
    try {
      const result = await apply(report([finding(dir, { ruleId: "test.gradle" })]), {
        assumeYes: true,
        tiers: { "test.gradle": "green" },
      });
      expect(result.outcomes[0]?.status).toBe("skipped");
      expect(result.outcomes[0]?.detail).toMatch(/gradle đang chạy/);
      expect(await exists(join(dir, "blob.bin"))).toBe(true);
    } finally {
      seam.restore();
    }
  });

  test.skipIf(process.platform === "win32")("a pnpm process under node blocks the pnpm store rule", async () => {
    const dir = join(sandbox, "pnpm-store");
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, "blob.bin"), "payload");
    await writeRules(
      `- id: test.pnpm\n  tier: green\n  desc: pnpm\n  paths: { all: ${JSON.stringify(dir)} }\n  nativeCommand: pnpm store prune\n`,
    );
    const seam = await fakePs(["node /Users/me/Library/pnpm/pnpm.cjs install"]);
    try {
      const result = await apply(report([finding(dir, { ruleId: "test.pnpm" })]), {
        assumeYes: true,
        tiers: { "test.pnpm": "green" },
      });
      expect(result.outcomes[0]?.status).toBe("skipped");
      expect(await exists(join(dir, "blob.bin"))).toBe(true);
    } finally {
      seam.restore();
    }
  });

  test("an ambient npm exec server does not block the npm cache rule", async () => {
    const dir = join(sandbox, "npm-cache-exec");
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, "blob.bin"), "payload");
    await writeRules(
      `- id: test.npm\n  tier: green\n  desc: npm\n  paths: { all: ${JSON.stringify(dir)} }\n  nativeCommand: npm cache verify\n`,
    );
    const seam = await fakePs(["npm exec @scope/server --mcp"]);
    try {
      const result = await apply(report([finding(dir, { ruleId: "test.npm" })]), {
        assumeYes: true,
        tiers: { "test.npm": "green" },
      });
      expect(result.outcomes[0]?.status).toBe("deleted");
    } finally {
      seam.restore();
    }
  });

  test.skipIf(process.platform !== "win32")("a listing with image names only keeps the tool caches", async () => {
    const dir = join(sandbox, "npm-cache-nameonly");
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, "blob.bin"), "payload");
    await writeRules(
      `- id: test.npm\n  tier: green\n  desc: npm\n  paths: { all: ${JSON.stringify(dir)} }\n  nativeCommand: npm cache verify\n`,
    );
    const result = await apply(report([finding(dir, { ruleId: "test.npm" })]), {
      assumeYes: true,
      tiers: { "test.npm": "green" },
    });
    expect(result.outcomes[0]?.status).toBe("skipped");
    expect(result.outcomes[0]?.detail).toMatch(/không xác định được/);
    expect(await exists(join(dir, "blob.bin"))).toBe(true);
  });

  test("no process listing at all keeps the fail-closed behaviour", async () => {
    const dir = join(sandbox, "npm-cache-unknown");
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, "blob.bin"), "payload");
    await writeRules(
      `- id: test.npm\n  tier: green\n  desc: npm\n  paths: { all: ${JSON.stringify(dir)} }\n  nativeCommand: npm cache verify\n`,
    );
    const seam = await fakeNoListing();
    try {
      const result = await apply(report([finding(dir, { ruleId: "test.npm" })]), {
        assumeYes: true,
        tiers: { "test.npm": "green" },
      });
      expect(result.outcomes[0]?.status).toBe("skipped");
      expect(result.outcomes[0]?.detail).toMatch(/không liệt kê được/);
      expect(await exists(join(dir, "blob.bin"))).toBe(true);
    } finally {
      seam.restore();
    }
  });
});

describe("the apply report separates deleted bytes from the volume delta", () => {
  test("only the deleted outcomes contribute to the deleted bytes", async () => {
    const deleted = join(sandbox, "deleted-cache");
    const skipped = join(sandbox, "skipped-cache");
    const failed = join(sandbox, "Documents", "failed-cache");
    const locked = join(sandbox, "locked-cache");
    for (const dir of [deleted, skipped, failed, locked]) {
      await mkdir(dir, { recursive: true });
      await writeFile(join(dir, "blob.bin"), Buffer.alloc(2048, 3));
    }
    await chmod(locked, 0o500);
    await writeRules(
      `- id: test.cache\n  tier: green\n  desc: cache\n  paths: { all: ${JSON.stringify(deleted)} }\n` +
        `- id: test.other\n  tier: green\n  desc: other\n  paths: { all: ${JSON.stringify(skipped)} }\n` +
        `- id: test.locked\n  tier: green\n  desc: locked\n  paths: { all: ${JSON.stringify(locked)} }\n`,
    );

    const result = await apply(
      report([
        finding(deleted, { bytes: 2048 }),
        finding(skipped, { bytes: 4096, ruleId: "test.other" }),
        finding(failed, { bytes: 8192, ruleId: "test.other" }),
        finding(locked, { bytes: 16384, ruleId: "test.locked" }),
      ]),
      { assumeYes: true, tiers: { "test.cache": "green", "test.locked": "green" } },
    );

    const byPath = (path: string) => result.outcomes.find((outcome) => outcome.path === path);
    expect(byPath(deleted)?.status).toBe("deleted");
    expect(byPath(deleted)?.bytes).toBe(2048);
    expect(byPath(skipped)?.status).toBe("skipped");
    expect(byPath(skipped)?.bytes).toBe(0);
    expect(byPath(failed)?.status).toBe("failed");
    expect(byPath(failed)?.bytes).toBe(0);
    expect(result.deletedBytes).toBe(2048);
    expect(result.freed).toBe(Math.max(0, result.freeAfter - result.freeBefore));
    await chmod(locked, 0o700);
  });

  test.skipIf(process.platform === "win32")("a delete that cannot succeed contributes no bytes", async () => {
    const locked = join(sandbox, "locked-cache");
    await mkdir(locked, { recursive: true });
    await writeFile(join(locked, "blob.bin"), Buffer.alloc(2048, 3));
    await chmod(locked, 0o500);
    await writeRules(
      `- id: test.locked\n  tier: green\n  desc: locked\n  paths: { all: ${JSON.stringify(locked)} }\n`,
    );
    const result = await apply(report([finding(locked, { bytes: 16384, ruleId: "test.locked" })]), {
      assumeYes: true,
      tiers: { "test.locked": "green" },
    });
    expect(result.outcomes[0]?.status).toBe("failed");
    expect(result.outcomes[0]?.bytes).toBe(0);
    expect(result.deletedBytes).toBe(0);
    await chmod(locked, 0o700);
  });
});

describe("nested paths are counted once", () => {
  test("a parent and a child directory are not counted twice", async () => {
    const outer = join(sandbox, "outer");
    const inner = join(outer, "inner");
    await mkdir(inner, { recursive: true });
    await writeFile(join(inner, "blob.bin"), Buffer.alloc(1000, 5));

    const adjusted = adjustScanAccounting(
      report([finding(outer, { bytes: 1000 }), finding(inner, { bytes: 1000 })]),
    );

    expect(adjusted.reclaimable).toBe(1000);
    expect(adjusted.totals.green.bytes).toBe(1000);
  });

  test("the deleted bytes do not count a parent and its child twice", async () => {
    const outer = join(sandbox, "outer-delete");
    const inner = join(outer, "inner");
    await mkdir(inner, { recursive: true });
    await writeFile(join(inner, "blob.bin"), Buffer.alloc(1000, 5));
    await writeRules(
      `- id: test.cache\n  tier: green\n  desc: cache\n  paths: { all: ${JSON.stringify(outer)} }\n`,
    );

    const result = await apply(
      report([finding(inner, { bytes: 1000 }), finding(outer, { bytes: 1000 })]),
      { assumeYes: true, tiers: { "test.cache": "green" } },
    );

    expect(result.deletedBytes).toBe(1000);
    expect(result.outcomes.filter((outcome) => outcome.status === "deleted").length).toBe(2);
  });

  test("the accounting helper drops a nested path and keeps the parent", () => {
    expect(
      accountedBytes([
        { path: "/a/outer", bytes: 100 },
        { path: "/a/outer/inner", bytes: 100 },
        { path: "/b/other", bytes: 50 },
      ]),
    ).toBe(150);
  });
});

describe("the rule fields that used to be inert now protect the delete", () => {
  test("staleDays refuses a cache that is not stale enough", async () => {
    const dir = join(sandbox, "fresh-stale");
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, "blob.bin"), "payload");
    await writeRules(
      `- id: test.cache\n  tier: green\n  desc: cache\n  paths: { all: ${JSON.stringify(dir)} }\n  staleDays: 30\n`,
    );

    const result = await apply(report([finding(dir)]), { assumeYes: true, tiers: { "test.cache": "green" } });

    expect(result.outcomes[0]?.status).toBe("skipped");
    expect(result.outcomes[0]?.detail).toMatch(/rule yêu cầu ≥ 30 ngày/);
    expect(await exists(join(dir, "blob.bin"))).toBe(true);
  });

  test("staleDays lets an old cache through", async () => {
    const dir = join(sandbox, "old-stale");
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, "blob.bin"), "payload");
    const old = new Date(Date.now() - 40 * DAY);
    await utimes(join(dir, "blob.bin"), old, old);
    await utimes(dir, old, old);
    await writeRules(
      `- id: test.cache\n  tier: green\n  desc: cache\n  paths: { all: ${JSON.stringify(dir)} }\n  staleDays: 30\n`,
    );

    const result = await apply(report([finding(dir, { mtime: old.getTime() }) ]), {
      assumeYes: true,
      tiers: { "test.cache": "green" },
    });

    expect(result.outcomes[0]?.status).toBe("deleted");
    expect(await exists(dir)).toBe(false);
  });

  test("gitClean refuses a path in a dirty repository", async () => {
    const repo = join(sandbox, "gitclean-repo");
    await mkdir(repo, { recursive: true });
    const git = (args: string[]): void => {
      execFileSync("git", args, { cwd: repo, stdio: "ignore" });
    };
    git(["init", "-q"]);
    git(["config", "user.email", "dustless@test.local"]);
    git(["config", "user.name", "dustless"]);
    git(["config", "commit.gpgsign", "false"]);
    const out = join(repo, "out");
    await mkdir(out, { recursive: true });
    await writeFile(join(out, "blob.bin"), "payload");
    git(["add", "-A"]);
    git(["commit", "-q", "-m", "init"]);
    await writeFile(join(repo, "scratch.txt"), "uncommitted\n");
    await writeRules(
      `- id: test.cache\n  tier: green\n  desc: cache\n  paths: { all: ${JSON.stringify(out)} }\n  gitClean: true\n`,
    );

    const result = await apply(report([finding(out)]), { assumeYes: true, tiers: { "test.cache": "green" } });

    expect(result.outcomes[0]?.status).toBe("skipped");
    expect(result.outcomes[0]?.detail).toMatch(/git/);
    expect(await exists(join(out, "blob.bin"))).toBe(true);
  });
});

describe("a git check that cannot run blocks the finding", () => {
  test("a broken .git/config cannot verify the path and the finding is not deleted", async () => {
    const repo = join(sandbox, "broken-git-repo");
    await mkdir(repo, { recursive: true });
    const git = (args: string[]): void => {
      execFileSync("git", args, { cwd: repo, stdio: "ignore" });
    };
    git(["init", "-q"]);
    git(["config", "user.email", "dustless@test.local"]);
    git(["config", "user.name", "dustless"]);
    git(["config", "commit.gpgsign", "false"]);
    const cache = join(repo, "cache");
    await mkdir(cache, { recursive: true });
    await writeFile(join(cache, "blob.bin"), "payload");
    git(["add", "-A"]);
    git(["commit", "-q", "-m", "init"]);
    await writeFile(join(repo, ".git", "config"), "[core\nthis is not valid\n");
    await writeRules(
      `- id: test.cache\n  tier: green\n  desc: cache\n  paths: { all: ${JSON.stringify(cache)} }\n  requireVerify: not_in_gitignore\n`,
    );

    const result = await apply(report([finding(cache)]), { assumeYes: true, tiers: { "test.cache": "green" } });

    expect(result.outcomes[0]?.status).toBe("skipped");
    expect(result.outcomes[0]?.detail).toMatch(/could not verify/);
    expect(await exists(join(cache, "blob.bin"))).toBe(true);
  });
});
