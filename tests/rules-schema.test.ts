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

  test("a tier outside green and yellow is still rejected", () => {
    expect(defect({ id: "test.tier", tier: "red", desc: "d", paths: { all: "~/x" }, recoveryLabel: "download" }, true)).toContain("green");
  });
});
