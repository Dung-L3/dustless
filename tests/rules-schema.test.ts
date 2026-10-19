import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Rule } from "../src/types.ts";
import { defect, loadRules } from "../src/core/rules.ts";

let dir: string;
let xdg: string;
const originalXdg = process.env["XDG_CONFIG_HOME"];
let seq = 0;

const writeRule = async (body: string): Promise<string> => {
  seq += 1;
  const file = join(dir, `rules-${seq}.yaml`);
  await writeFile(file, body);
  return file;
};

const yamlRule = (extra: string): string => `- id: test.probe\n  tier: green\n  desc: d\n  paths: { all: "~/x" }\n${extra}`;

const raw = (extra: Record<string, unknown>): Record<string, unknown> => ({
  id: `test.${++seq}`,
  tier: "green",
  desc: "d",
  paths: { all: "~/x" },
  ...extra,
});

const loaded = async (file: string, id: string): Promise<Rule> => {
  const found = (await loadRules(file)).find((rule) => rule.id === id);
  expect(found).toBeDefined();
  return found as Rule;
};

describe("rules schema", () => {
  beforeAll(async () => {
    dir = await mkdtemp(join(tmpdir(), "dustless-schema-"));
    xdg = await mkdtemp(join(tmpdir(), "dustless-schema-xdg-"));
    process.env["XDG_CONFIG_HOME"] = join(xdg, "config");
    await mkdir(join(xdg, "config", "dustless"), { recursive: true });
  });

  afterAll(async () => {
    if (originalXdg === undefined) delete process.env["XDG_CONFIG_HOME"];
    else process.env["XDG_CONFIG_HOME"] = originalXdg;
    await rm(xdg, { recursive: true, force: true });
    await rm(dir, { recursive: true, force: true });
  });

  test("every shipped rule carries a recoveryLabel", async () => {
    const rules = await loadRules();
    expect(rules).toHaveLength(26);
    expect(rules.every((rule) => rule.recoveryLabel === "download" || rule.recoveryLabel === "rebuild")).toBe(true);
  });

  test("the shipped rule set rejects a rule without a recoveryLabel", () => {
    expect(defect({ id: "test.missing", tier: "green", desc: "d", paths: { all: "~/x" } }, true)).toContain("recoveryLabel");
  });

  test("a recoveryLabel outside download or rebuild is rejected", async () => {
    const file = await writeRule(yamlRule("  recoveryLabel: delete-server\n"));
    expect(loadRules(file)).rejects.toThrow(/recoveryLabel/);
  });

  test("a custom rule without a recoveryLabel still loads", async () => {
    const id = "test.tolerant";
    const file = await writeRule(`- id: ${id}\n  tier: green\n  desc: d\n  paths: { all: "~/x" }\n`);
    const rule = await loaded(file, id);
    expect(rule.recoveryLabel).toBeUndefined();
  });

  test("recoveryLabel download and rebuild are both accepted", () => {
    expect(defect(raw({ recoveryLabel: "download" }), true)).toBeNull();
    expect(defect(raw({ recoveryLabel: "rebuild" }), true)).toBeNull();
  });

  test("busyProcesses is carried through", async () => {
    const id = "test.busy";
    const file = await writeRule(`- id: ${id}\n  tier: green\n  desc: d\n  paths: { all: "~/x" }\n  busyProcesses: [docker, npm]\n`);
    const rule = await loaded(file, id);
    expect(rule.busyProcesses).toEqual(["docker", "npm"]);
  });

  test("an empty busyProcesses list is rejected", () => {
    expect(defect(raw({ busyProcesses: [] }), false)).toContain("busyProcesses");
  });

  test("busyProcesses with an empty name is rejected", () => {
    expect(defect(raw({ busyProcesses: ["", "x"] }), false)).toContain("busyProcesses");
  });

  test("a bare-string busyProcesses is rejected", () => {
    expect(defect(raw({ busyProcesses: "docker" }), false)).toContain("busyProcesses");
  });

  test("staleDays 14 is accepted and non-positive integers are rejected", () => {
    expect(defect(raw({ staleDays: 14 }), false)).toBeNull();
    expect(defect(raw({ staleDays: 0 }), false)).toContain("staleDays");
    expect(defect(raw({ staleDays: -1 }), false)).toContain("staleDays");
    expect(defect(raw({ staleDays: 1.5 }), false)).toContain("staleDays");
    expect(defect(raw({ staleDays: "14" }), false)).toContain("staleDays");
  });

  test("gitClean accepts a boolean and rejects a string", () => {
    expect(defect(raw({ gitClean: true }), false)).toBeNull();
    expect(defect(raw({ gitClean: false }), false)).toBeNull();
    expect(defect(raw({ gitClean: "yes" }), false)).toContain("gitClean");
  });

  test("nativeCommand accepts tool-owned commands", () => {
    expect(defect(raw({ nativeCommand: "brew cleanup" }), false)).toBeNull();
    expect(defect(raw({ nativeCommand: "simctl delete unavailable" }), false)).toBeNull();
  });

  test("nativeCommand rejects a path first token", () => {
    expect(defect(raw({ nativeCommand: "/usr/local/bin/rm -rf /" }), false)).toContain("nativeCommand");
    expect(defect(raw({ nativeCommand: "bin/rm -rf /" }), false)).toContain("nativeCommand");
    expect(defect(raw({ nativeCommand: "..\\rm" }), false)).toContain("nativeCommand");
  });

  test("nativeCommand rejects shell metacharacters", () => {
    expect(defect(raw({ nativeCommand: "rm; rm -rf /" }), false)).toContain("nativeCommand");
    expect(defect(raw({ nativeCommand: "$(whoami)" }), false)).toContain("nativeCommand");
    expect(defect(raw({ nativeCommand: "a|b" }), false)).toContain("nativeCommand");
    expect(defect(raw({ nativeCommand: "a>b" }), false)).toContain("nativeCommand");
    expect(defect(raw({ nativeCommand: "a<b" }), false)).toContain("nativeCommand");
    expect(defect(raw({ nativeCommand: "a`b`" }), false)).toContain("nativeCommand");
    expect(defect(raw({ nativeCommand: "a&b" }), false)).toContain("nativeCommand");
  });

  test("an unknown field is still rejected", () => {
    expect(defect(raw({ turbo: true }), false)).toContain("trường");
  });

  test("match must be a string that compiles as a regular expression", () => {
    expect(defect(raw({ match: "^(Cache|Code Cache)$" }), false)).toBeNull();
    expect(defect(raw({ match: "[" }), false)).toContain("match");
    expect(defect(raw({ match: 7 }), false)).toContain("match");
  });

  test("requireVerify must be a known verifier", () => {
    for (const name of ["gradle_version_unused", "git_clean", "not_in_gitignore"]) {
      expect(defect(raw({ requireVerify: name }), false)).toBeNull();
    }
    expect(defect(raw({ requireVerify: "trust_me" }), false)).toContain("requireVerify");
    expect(defect(raw({ requireVerify: true }), false)).toContain("requireVerify");
  });

  test("minAgeDays must be a non-negative integer", () => {
    expect(defect(raw({ minAgeDays: 0 }), false)).toBeNull();
    expect(defect(raw({ minAgeDays: 30 }), false)).toBeNull();
    expect(defect(raw({ minAgeDays: -1 }), false)).toContain("minAgeDays");
    expect(defect(raw({ minAgeDays: 1.5 }), false)).toContain("minAgeDays");
    expect(defect(raw({ minAgeDays: "30" }), false)).toContain("minAgeDays");
  });

  test("rule ids cannot carry YAML or path syntax", () => {
    expect(defect(raw({ id: "ok.rule-1_2" }), false)).toBeNull();
    expect(defect(raw({ id: "bad id" }), false)).toContain("id");
    expect(defect(raw({ id: "bad\nrule" }), false)).toContain("id");
    expect(defect(raw({ id: "../escape" }), false)).toContain("id");
  });

  test("windows browser rules target cache leaves, never the profile root", async () => {
    const rules = await loadRules();
    for (const id of ["browser.chrome", "browser.edge"]) {
      const win = rules.find((rule) => rule.id === id)?.paths.win;
      const patterns = Array.isArray(win) ? win : [win];
      expect(patterns.length).toBeGreaterThan(0);
      for (const pattern of patterns) {
        const leaf = (pattern ?? "").split("/").pop();
        expect(leaf).not.toBe("User Data");
        expect(leaf).not.toBe("Default");
        expect(leaf).not.toBe("*");
        expect(leaf).not.toMatch(/^Profile /);
      }
    }
  });

  test("shipped windows paths only reference environment variables that exist", async () => {
    const rules = await loadRules();
    const variables = rules
      .flatMap((rule) => Object.values(rule.paths))
      .flat()
      .flatMap((pattern) => [...(pattern ?? "").matchAll(/%([A-Za-z_][A-Za-z0-9_]*)%/g)].map((match) => match[1]));
    expect([...new Set(variables)]).toEqual(["LOCALAPPDATA", "USERPROFILE"]);
  });

  test("a tier outside green and yellow is still rejected", () => {
    expect(defect({ id: "test.tier", tier: "red", desc: "d", paths: { all: "~/x" }, recoveryLabel: "download" }, true)).toContain("green");
  });
});
