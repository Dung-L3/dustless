import { afterAll, describe, expect, test } from "bun:test";
import { chmod, mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Finding, ScanReport } from "../src/types.ts";
import { SCHEMA_VERSION } from "../src/types.ts";
import { apply } from "../src/core/apply.ts";
import { defect } from "../src/core/rules.ts";

const sandbox = await mkdtemp(join(tmpdir(), "dustless-scope-apply-"));
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
  note: [],
  ...overrides,
});

const report = (findings: Finding[]): ScanReport => ({
  schemaVersion: SCHEMA_VERSION,
  findings,
  totals: { green: { count: 0, bytes: 0 }, yellow: { count: 0, bytes: 0 }, red: { count: 0, bytes: 0 }, blocked: { count: 0, bytes: 0 } },
  reclaimable: 0,
  freeBefore: 0,
  platform: "mac",
  scannedMs: 0,
  unscannable: [],
  unscannableSummary: { absent: 0, no_access: 0, not_supported: 0, error: 0, red: 0, protected: 0 },
});

const writeRules = async (body: string): Promise<void> => {
  await mkdir(join(sandbox, "config", "dustless"), { recursive: true });
  await writeFile(join(sandbox, "config", "dustless", "rules.yaml"), body);
};

const plant = async (name: string): Promise<string> => {
  const dir = join(sandbox, name);
  await mkdir(dir, { recursive: true });
  await writeFile(join(dir, "blob.bin"), "payload");
  return dir;
};

afterAll(async () => {
  if (originalXdg === undefined) delete process.env["XDG_CONFIG_HOME"];
  else process.env["XDG_CONFIG_HOME"] = originalXdg;
  await chmod(sandbox, 0o700).catch(() => undefined);
  await rm(sandbox, { recursive: true, force: true });
});

describe("a rule whose scope reaches the direct children of $HOME is refused at apply", () => {
  test("a hand-written rule is refused and the payload survives", async () => {
    const dir = await plant("handwritten");
    await writeRules(
      `- id: test.cache\n  tier: green\n  desc: cache\n  paths: { all: "~/*" }\n  recoveryLabel: download\n`,
    );

    const result = await apply(report([finding(dir)]), { assumeYes: true, tiers: { "test.cache": "green" } });

    expect(result.outcomes[0]?.status).toBe("failed");
    expect(result.outcomes[0]?.detail?.code).toBe("protected");
    expect(result.deletedBytes).toBe(0);
    expect(await exists(join(dir, "blob.bin"))).toBe(true);
  });

  test("the same scope is refused when the rule is created through rule add", () => {
    const problem = defect(
      { id: "test.cache", tier: "green", desc: "cache", recoveryLabel: "download", paths: { all: "~/*" } },
      false,
    );
    expect(problem).not.toBeNull();
    expect(problem).toContain("paths.all");
  });

  test("a rule whose scope is inside $HOME is still deleted", async () => {
    const dir = await plant("inside");
    await writeRules(
      `- id: test.cache\n  tier: green\n  desc: cache\n  paths: { all: ${JSON.stringify(join(sandbox, "inside"))} }\n  recoveryLabel: download\n`,
    );

    const result = await apply(report([finding(dir)]), { assumeYes: true, tiers: { "test.cache": "green" } });

    expect(result.outcomes[0]?.status).toBe("deleted");
    expect(await exists(dir)).toBe(false);
  });
});

describe("the delete path refuses a finding it cannot tie to a rule", () => {
  test("a rule id that is not in the rule set is skipped, never deleted", async () => {
    const dir = await plant("unknown-rule");
    await writeRules(
      `- id: test.cache\n  tier: green\n  desc: cache\n  paths: { all: ${JSON.stringify(join(sandbox, "unknown-rule"))} }\n  recoveryLabel: download\n`,
    );

    const result = await apply(report([finding(dir, { ruleId: "test.absent" })]), {
      assumeYes: true,
      tiers: { "test.absent": "green" },
    });

    expect(result.outcomes[0]?.status).toBe("skipped");
    expect(result.outcomes[0]?.detail?.code).toBe("unresolvable");
    expect(result.deletedBytes).toBe(0);
    expect(await exists(join(dir, "blob.bin"))).toBe(true);
  });
});

describe("the busy-process gate is only paid for by a rule that needs it", () => {
  test.skipIf(process.platform === "win32")("the listing the gate reads is the whole command line", async () => {
    const narrow = await Bun.$`ps -Ao args=`.quiet();
    const wide = await Bun.$`ps -Aww -o args=`.quiet();
    const longest = (text: string): number =>
      text.split("\n").reduce((max, line) => Math.max(max, line.length), 0);
    expect(longest(narrow.stdout.toString())).toBe(longest(wide.stdout.toString()));
    expect(longest(narrow.stdout.toString())).toBeGreaterThan(80);
  });

  test("a rule with no busy process never lists the process table", async () => {
    const dir = await plant("no-busy");
    await writeRules(
      `- id: test.cache\n  tier: green\n  desc: cache\n  paths: { all: ${JSON.stringify(join(sandbox, "no-busy"))} }\n  recoveryLabel: download\n`,
    );
    const bin = join(sandbox, "bin");
    await mkdir(bin, { recursive: true });
    const argv = join(bin, "ps-argv.txt");
    await writeFile(join(bin, "ps"), `#!/bin/sh\necho "$@" > ${JSON.stringify(argv)}\nexit 1\n`);
    await chmod(join(bin, "ps"), 0o755);
    const prior = process.env["PATH"];
    process.env["PATH"] = `${bin}:${prior ?? ""}`;
    try {
      const result = await apply(report([finding(dir)]), { assumeYes: true, tiers: { "test.cache": "green" } });
      expect(result.outcomes[0]?.status).toBe("deleted");
      expect(await exists(argv)).toBe(false);
    } finally {
      if (prior === undefined) delete process.env["PATH"];
      else process.env["PATH"] = prior;
    }
  });

  test.skipIf(process.platform === "win32")("a rule that declares a busy process does list the process table", async () => {
    const dir = await plant("busy");
    await writeRules(
      `- id: test.npm\n  tier: green\n  desc: npm\n  paths: { all: ${JSON.stringify(join(sandbox, "busy"))} }\n  busyProcesses: ["npm"]\n  recoveryLabel: download\n`,
    );
    const bin = join(sandbox, "bin-busy");
    await mkdir(bin, { recursive: true });
    const argv = join(bin, "ps-argv.txt");
    await writeFile(join(bin, "ps"), `#!/bin/sh\necho "$@" > ${JSON.stringify(argv)}\necho "sleep 1000"\nexit 0\n`);
    await chmod(join(bin, "ps"), 0o755);
    const prior = process.env["PATH"];
    process.env["PATH"] = `${bin}:${prior ?? ""}`;
    try {
      const result = await apply(report([finding(dir, { ruleId: "test.npm" })]), {
        assumeYes: true,
        tiers: { "test.npm": "green" },
      });
      expect(result.outcomes[0]?.status).toBe("deleted");
      const recorded = await readFile(argv, "utf8");
      expect(recorded).toContain("args=");
    } finally {
      if (prior === undefined) delete process.env["PATH"];
      else process.env["PATH"] = prior;
    }
  });
});
