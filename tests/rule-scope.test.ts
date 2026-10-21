import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { HOME, patternVerdict, resolvePattern } from "../src/core/paths.ts";
import { defect, loadRules, scopeDefect } from "../src/core/rules.ts";
import { scan } from "../src/core/scan.ts";

const sandbox = await mkdtemp(join(tmpdir(), "dustless-rule-scope-"));
const configHome = join(sandbox, "config");
const originalXdg = process.env["XDG_CONFIG_HOME"];
process.env["XDG_CONFIG_HOME"] = configHome;

const writeRules = async (body: string): Promise<string> => {
  await mkdir(join(configHome, "dustless"), { recursive: true });
  const file = join(configHome, "dustless", "rules.yaml");
  await writeFile(file, body);
  return file;
};

const rule = (paths: unknown): Record<string, unknown> => ({
  id: "test.scope",
  tier: "green",
  desc: "scope probe",
  recoveryLabel: "download",
  paths: { all: paths },
});

afterAll(async () => {
  if (originalXdg === undefined) delete process.env["XDG_CONFIG_HOME"];
  else process.env["XDG_CONFIG_HOME"] = originalXdg;
  spawnChmodFix(sandbox);
  await rm(sandbox, { recursive: true, force: true });
});

function spawnChmodFix(dir: string): void {
  Bun.spawnSync(["chmod", "-R", "u+rwX", dir]);
}

describe("rule scope validation", () => {
  test("a rule that reaches $HOME itself is refused", () => {
    for (const pattern of ["~", HOME, `${HOME}/`, `${HOME}/.`]) {
      const problem = defect(rule(pattern), false);
      expect(problem).not.toBeNull();
      expect(problem).toContain("$HOME");
    }
  });

  test("a rule that reaches an ancestor of $HOME is refused", () => {
    for (const pattern of ["~/..", dirname(HOME), dirname(HOME) + "/", "/"]) {
      const problem = defect(rule(pattern), false);
      expect(problem).not.toBeNull();
    }
  });

  test("a wildcard that lands on the direct children of $HOME is refused", () => {
    for (const pattern of ["~/*", "~/*/", `${HOME}/*`, "~/*.txt", "~/*/../x"]) {
      const problem = defect(rule(pattern), false);
      expect(problem).not.toBeNull();
      expect(problem).toContain("paths.all");
    }
  });

  test("a rule that names a path below $HOME is accepted", () => {
    for (const pattern of ["~/x", "~/.cache/x", "~/.gradle/caches/*", "~/*/node_modules", "~/*/*/node_modules"]) {
      expect(defect(rule(pattern), false)).toBeNull();
    }
  });

  test("a rule that names a path outside $HOME is accepted", () => {
    expect(defect(rule("/opt/homebrew/var/homebrew/cache"), false)).toBeNull();
    expect(defect(rule("/tmp/dustless-somewhere/cache"), false)).toBeNull();
  });

  test("a pattern that escapes $HOME through .. is refused", () => {
    expect(defect(rule("~/../elsewhere"), false)).not.toBeNull();
    expect(defect(rule("~/*/../elsewhere"), false)).not.toBeNull();
  });

  test("the verdict separates a protected scope from an unsupported pattern", () => {
    expect(patternVerdict("/")).toMatchObject({ ok: false, kind: "protected" });
    expect(patternVerdict("~/*")).toMatchObject({ ok: false, kind: "protected" });
    expect(patternVerdict("~/.cache/**")).toMatchObject({ ok: false, kind: "unsupported" });
    expect(patternVerdict("~/.cache/x")).toMatchObject({ ok: true });
  });

  test("every shipped rule passes the scope check", async () => {
    const rules = await loadRules();
    expect(rules.length).toBeGreaterThan(20);
    for (const shipped of rules) {
      expect(scopeDefect(shipped.paths)).toBeNull();
    }
  });

  test("a list of paths is checked entry by entry", () => {
    expect(defect(rule(["~/.cache/x", "~/*"]), false)).not.toBeNull();
    expect(defect(rule(["~/.cache/x", "~/.cache/y"]), false)).toBeNull();
  });
});

describe("glob expansion", () => {
  let tree: string;
  let pinned: string;

  beforeAll(async () => {
    tree = join(sandbox, "tree");
    await mkdir(join(tree, "a", "b", "node_modules"), { recursive: true });
    await mkdir(join(tree, "a", "b", "c", "node_modules"), { recursive: true });
    await mkdir(join(tree, "a", "b", "c", "d", "node_modules"), { recursive: true });
    await mkdir(join(tree, "a", "build"), { recursive: true });
    await mkdir(join(tree, "one"), { recursive: true });
    await mkdir(join(tree, "two"), { recursive: true });
    await writeFile(join(tree, "one", "blob.bin"), Buffer.alloc(16, 1));
    await writeFile(join(tree, "two", "blob.bin"), Buffer.alloc(16, 1));
    pinned = join(sandbox, "pinned");
    await mkdir(join(pinned, "keep", "other", "node_modules"), { recursive: true });
  });

  test("one wildcard level lists the direct children", async () => {
    const result = await resolvePattern(join(tree, "*"));
    expect(result.paths).toEqual([join(tree, "a"), join(tree, "one"), join(tree, "two")]);
    expect(result.error).toBeUndefined();
  });

  test("two wildcard levels reach a nested directory", async () => {
    const result = await resolvePattern(join(tree, "*", "*", "node_modules"));
    expect(result.paths).toEqual([join(tree, "a", "b", "node_modules")]);
  });

  test("three wildcard levels reach a deeper directory", async () => {
    const result = await resolvePattern(join(tree, "*", "*", "*", "node_modules"));
    expect(result.paths).toEqual([join(tree, "a", "b", "c", "node_modules")]);
  });

  test("a wildcard inside a segment matches that segment only", async () => {
    await mkdir(join(tree, "avd", "Pixel.avd"), { recursive: true });
    await mkdir(join(tree, "avd", "plain"), { recursive: true });
    const result = await resolvePattern(join(tree, "avd", "*.avd"));
    expect(result.paths).toEqual([join(tree, "avd", "Pixel.avd")]);
  });

  test("a pattern with no match is empty and not an error", async () => {
    const result = await resolvePattern(join(tree, "*", "nothing-here"));
    expect(result.paths).toEqual([]);
    expect(result.error).toBeUndefined();
  });

  test("a missing base directory is reported as absent", async () => {
    const result = await resolvePattern(join(tree, "missing", "*"));
    expect(result.paths).toEqual([]);
    expect(result.error?.code).toBe("ENOENT");
  });

  test("the entry budget is reported instead of silently truncating", async () => {
    const result = await resolvePattern(join(tree, "*"), { maxDepth: 12, maxEntries: 1 });
    expect(result.paths).toEqual([]);
    expect(result.error?.code).toBe("EBUDGET");
  });

  test("a pattern never matches outside its own shape", async () => {
    const deep = await resolvePattern(join(tree, "*", "*", "node_modules"));
    expect(deep.paths).not.toContain(join(tree, "a", "b", "c", "node_modules"));
    const pinnedResult = await resolvePattern(join(pinned, "*", "other", "node_modules"));
    expect(pinnedResult.paths).toEqual([join(pinned, "keep", "other", "node_modules")]);
    expect(pinnedResult.paths).not.toContain(join(tree, "a", "b", "node_modules"));
  });

  test.skipIf(process.platform === "win32")("an unreadable directory is reported as no access", async () => {
    const locked = join(sandbox, "locked");
    await mkdir(locked, { recursive: true });
    await chmod(locked, 0o000);
    const result = await resolvePattern(join(locked, "*"));
    expect(result.paths).toEqual([]);
    expect(result.error?.code).toBe("EACCES");
    await chmod(locked, 0o700);
  });
});

describe("the scan refuses a protected scope", () => {
  test("a rule for the filesystem root yields no finding and is reported as protected", async () => {
    await writeRules(`- id: test.root\n  tier: green\n  desc: root\n  paths: { all: "/" }\n`);
    const report = await scan({ roots: [sandbox] });
    expect(report.findings.some((f) => f.ruleId === "test.root")).toBe(false);
    const unscannable = report.unscannable.find((r) => r.ruleId === "test.root");
    expect(unscannable?.reason).toBe("protected");
    expect(unscannable?.pathPatterns).toContain("/");
    expect(report.unscannableSummary.protected).toBeGreaterThanOrEqual(1);
  });

  test("a rule for $HOME yields no finding and is reported as protected", async () => {
    await writeRules(`- id: test.home\n  tier: green\n  desc: home\n  paths: { all: "~" }\n`);
    const report = await scan({ roots: [sandbox] });
    expect(report.findings.some((f) => f.ruleId === "test.home")).toBe(false);
    expect(report.unscannable.find((r) => r.ruleId === "test.home")?.reason).toBe("protected");
  });

  test("a rule for the parent of $HOME yields no finding and is reported as protected", async () => {
    await writeRules(`- id: test.parent\n  tier: green\n  desc: parent\n  paths: { all: "${dirname(HOME)}" }\n`);
    const report = await scan({ roots: [sandbox] });
    expect(report.findings.some((f) => f.ruleId === "test.parent")).toBe(false);
    expect(report.unscannable.find((r) => r.ruleId === "test.parent")?.reason).toBe("protected");
  });

  test("a wildcard over the direct children of $HOME yields no finding and is reported as protected", async () => {
    await writeRules(`- id: test.children\n  tier: green\n  desc: children\n  paths: { all: "~/*" }\n`);
    const report = await scan({ roots: [sandbox] });
    expect(report.findings.some((f) => f.ruleId === "test.children")).toBe(false);
    expect(report.unscannable.find((r) => r.ruleId === "test.children")?.reason).toBe("protected");
  });

  test("a protected rule contributes nothing to the totals", async () => {
    await writeRules(
      `- id: test.root\n  tier: green\n  desc: root\n  paths: { all: "/" }\n` +
        `- id: test.home\n  tier: green\n  desc: home\n  paths: { all: "~" }\n`,
    );
    const report = await scan({ roots: [sandbox] });
    expect(report.findings).toEqual([]);
    expect(report.reclaimable).toBe(0);
    expect(report.totals.green.bytes).toBe(0);
    expect(report.totals.yellow.bytes).toBe(0);
    expect(report.unscannableSummary.protected).toBe(2);
  });

  test("an unsupported pattern is reported as not supported", async () => {
    await writeRules(`- id: test.deep\n  tier: green\n  desc: deep\n  paths: { all: "~/**/node_modules" }\n`);
    const report = await scan({ roots: [sandbox] });
    expect(report.findings.some((f) => f.ruleId === "test.deep")).toBe(false);
    expect(report.unscannable.find((r) => r.ruleId === "test.deep")?.reason).toBe("not_supported");
  });
});
