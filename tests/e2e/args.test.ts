import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import {
  applyJson,
  assertTempRoot,
  cleanupAll,
  exec,
  MB,
  plant,
  sandbox,
  scanJson,
  treeBytes,
  type Sandbox,
} from "./harness.ts";

afterAll(cleanupAll);

const exists = async (path: string): Promise<boolean> => await Bun.$`test -e ${path}`.quiet().nothrow().then((r) => r.exitCode === 0);

const oneJsonObject = (stdout: string): Record<string, unknown> => {
  expect(stdout.trim().split("\n")).toHaveLength(1);
  return JSON.parse(stdout) as Record<string, unknown>;
};

describe("apply --only-file deletes exactly the selected paths", () => {
  let box: Sandbox;
  const npm = (): string => join(box.home, ".npm", "_cacache");
  const bun = (): string => join(box.home, ".bun", "install", "cache");

  beforeAll(async () => {
    box = await sandbox("only");
    await plant(npm(), 2 * MB, 2);
    await plant(bun(), 1 * MB, 1);
  });
  afterAll(async () => {
    await box.dispose();
  });

  const select = async (paths: string[], name = "selection.json"): Promise<string> => {
    const file = join(box.home, name);
    await writeFile(file, JSON.stringify(paths));
    return file;
  };

  test("the report holds two deletable findings before anything is selected", async () => {
    expect(scanJson((await box.run(["scan", "--json"])).stdout).findings.map((f) => f.path).sort()).toEqual([npm(), bun()].sort());
  });

  test("only the listed path is deleted and the other is skipped, not deleted", async () => {
    const file = await select([npm()]);
    const run = await box.run(["apply", "--yes", "--json", "--only-file", file]);
    expect(run.code).toBe(0);
    const result = applyJson(run.stdout);
    expect(result.outcomes.find((o) => o.path === npm())?.status).toBe("deleted");
    expect(result.outcomes.find((o) => o.path === bun())?.status).toBe("skipped");
    expect(result.outcomes.find((o) => o.path === bun())?.detail).toMatch(/chọn/);
    expect(await exists(npm())).toBe(false);
    expect(await treeBytes(bun())).toBe(1 * MB);
  });

  test("a selected path that is not in the report is ignored and deletes nothing", async () => {
    const other = await sandbox("only-unknown");
    await plant(join(other.home, ".npm", "_cacache"), 1 * MB, 1);
    await plant(join(other.home, ".bun", "install", "cache"), 1 * MB, 1);
    const plainFile = join(other.home, "Documents", "notes.bin");
    await mkdir(join(other.home, "Documents"), { recursive: true });
    await writeFile(plainFile, "not a finding");
    const file = join(other.home, "selection.json");
    await writeFile(file, JSON.stringify([plainFile]));
    const run = await other.run(["apply", "--yes", "--json", "--only-file", file]);
    const result = applyJson(run.stdout);
    expect(run.code).toBe(0);
    expect(result.outcomes.length).toBeGreaterThan(0);
    expect(result.outcomes.every((o) => o.status === "skipped")).toBe(true);
    expect(result.outcomes.some((o) => o.status === "deleted")).toBe(false);
    expect(await treeBytes(join(other.home, ".npm", "_cacache"))).toBe(1 * MB);
    expect(await treeBytes(join(other.home, ".bun", "install", "cache"))).toBe(1 * MB);
    await other.dispose();
  });

  test("without the flag the behaviour is unchanged: every green finding goes", async () => {
    const plain = await sandbox("only-none");
    await plant(join(plain.home, ".npm", "_cacache"), 1 * MB, 1);
    await plant(join(plain.home, ".bun", "install", "cache"), 1 * MB, 1);
    const result = applyJson((await plain.run(["apply", "--yes", "--json"])).stdout);
    expect(result.outcomes.filter((o) => o.status === "deleted")).toHaveLength(2);
    await plain.dispose();
  });

  test("the confirmation summary counts only the selection", async () => {
    const asked = await sandbox("only-summary");
    await plant(join(asked.home, ".npm", "_cacache"), 1 * MB, 1);
    await plant(join(asked.home, ".bun", "install", "cache"), 1 * MB, 1);
    const file = join(asked.home, "selection.json");
    await writeFile(file, JSON.stringify([join(asked.home, ".npm", "_cacache")]));
    const run = await asked.run(["apply", "--only-file", file]);
    expect(run.code).toBe(0);
    expect(run.stdout).toContain("Đã hủy. Không có gì bị xóa");
    expect(run.stdout).toContain("1 mục tự động");
    expect(await treeBytes(join(asked.home, ".npm", "_cacache"))).toBe(1 * MB);
    expect(await treeBytes(join(asked.home, ".bun", "install", "cache"))).toBe(1 * MB);
    await asked.dispose();
  });
});

describe("a selection file that cannot be read deletes nothing", () => {
  let box: Sandbox;
  const cache = (): string => join(box.home, ".npm", "_cacache");

  beforeAll(async () => {
    box = await sandbox("only-broken");
    await plant(cache(), 2 * MB, 2);
  });
  afterAll(async () => {
    await box.dispose();
  });

  test("a missing file is a usage error on stdout as one JSON object", async () => {
    const run = await box.run(["apply", "--yes", "--json", "--only-file", join(box.home, "nope.json")]);
    expect(run.code).toBe(1);
    expect(String(oneJsonObject(run.stdout)["error"])).toMatch(/--only-file/);
    expect(await treeBytes(cache())).toBe(2 * MB);
  });

  test("a file that is not JSON, or not an array of strings, is refused", async () => {
    for (const [name, body] of [
      ["broken.json", "{not json"],
      ["object.json", '{"path":"/tmp/x"}'],
      ["mixed.json", '["/tmp/x", 7]'],
    ] as const) {
      const file = join(box.home, name);
      await writeFile(file, body);
      const run = await box.run(["apply", "--yes", "--json", "--only-file", file]);
      expect({ name, code: run.code }).toEqual({ name, code: 1 });
      expect(String(oneJsonObject(run.stdout)["error"])).toMatch(/--only-file/);
      expect(await treeBytes(cache())).toBe(2 * MB);
    }
  });

  test("the flag with no value is a usage error, not a selection of nothing", async () => {
    const run = await box.run(["apply", "--yes", "--json", "--only-file", "--json"]);
    expect(run.code).toBe(1);
    expect(String(oneJsonObject(run.stdout)["error"])).toMatch(/--only-file/);
    expect(await treeBytes(cache())).toBe(2 * MB);
  });

  test("a human run gets the same sentence on stderr and nothing on stdout", async () => {
    const run = await box.run(["apply", "--yes", "--only-file"]);
    expect(run.code).toBe(1);
    expect(run.stdout).toBe("");
    expect(run.stderr).toContain("--only-file");
  });

  test("--quiet never swallows the reason a run exited non-zero", async () => {
    const run = await box.run(["apply", "--yes", "--quiet", "--only-file"]);
    expect(run.code).toBe(1);
    expect(run.stdout).toBe("");
    expect(run.stderr).toContain("--only-file");
  });
});

describe("every argument error is one JSON object and exit 1", () => {
  let box: Sandbox;

  beforeAll(async () => {
    box = await sandbox("argerrors");
  });
  afterAll(async () => {
    await box.dispose();
  });

  const cases: [string, string[], RegExp][] = [
    ["apps --uninstall with no path", ["apps", "--uninstall", "--confirm", "--json"], /--uninstall/],
    ["awdl --on --off", ["awdl", "--on", "--off", "--json"], /--on|--off/],
    ["ram --kill with no pid", ["ram", "--kill", "--json"], /--kill/],
    ["largefiles --min-size with no value", ["largefiles", "--json", "--min-size", "--json"], /--min-size/],
    ["largefiles --limit with no value", ["largefiles", "--json", "--limit"], /--limit/],
    ["an unknown command", ["definitely-not-a-command", "--json"], /không hợp lệ/],
  ];

  for (const [label, argv, expected] of cases) {
    test(`${label}: exit 1, one JSON object, nothing on stderr`, async () => {
      const run = await box.run(argv);
      expect({ label, code: run.code }).toEqual({ label, code: 1 });
      expect(String(oneJsonObject(run.stdout)["error"])).toMatch(expected);
      expect(run.stderr).toBe("");
    });
  }

  test("rule validate --json speaks JSON on success", async () => {
    const good = join(box.home, "good.yaml");
    await writeFile(good, '- id: good.one\n  tier: green\n  desc: ok\n  paths: { all: "~/x" }\n');
    const ok = await box.run(["rule", "validate", good, "--json"]);
    expect(ok.code).toBe(0);
    expect(oneJsonObject(ok.stdout)["ok"]).toBe(true);
    const missing = await box.run(["rule", "validate", join(box.home, "nope.yaml"), "--json"]);
    expect(missing.code).toBe(1);
    expect(String(oneJsonObject(missing.stdout)["error"])).toMatch(/rules/);
  });

  test("net --print-privilege --json with no usable account reports one error", async () => {
    const run = await box.run(["net", "--print-privilege", "--json"]);
    expect(run.code).toBe(1);
    expect(String(oneJsonObject(run.stdout)["error"])).toMatch(/không dùng được|macOS/);
  });
});

describe.skipIf(process.platform !== "darwin")("net --print-privilege refuses an unresolvable service", () => {
  test("prints an error and exits 1 instead of a rule that cannot work", async () => {
    const box = await sandbox("privempty");
    const empty = assertTempRoot(join(box.home, "no-such-bin"));
    await mkdir(empty, { recursive: true });
    const run = await exec(
      ["net", "--print-privilege", "--json"],
      { PATH: empty, HOME: box.home, USER: "mac", NO_COLOR: "1" },
      "/",
    );
    expect(run.code).toBe(1);
    const error = String(oneJsonObject(run.stdout)["error"]);
    expect(error).toMatch(/dịch vụ|interface/);
    expect(error).not.toContain("NOPASSWD");
    await box.dispose();
  });
});
describe("arguments are validated before anything runs", () => {
  let box: Sandbox;

  beforeAll(async () => {
    box = await sandbox("flags");
  });
  afterAll(async () => {
    await box.dispose();
  });

  const commands = ["scan", "apply", "rule", "doctor", "net", "awdl", "ram", "apps", "largefiles"];

  test("an unknown flag is refused for every command, as one JSON object", async () => {
    for (const command of commands) {
      const run = await box.run([command, "--definitely-not-a-flag", "--json"]);
      expect({ command, code: run.code }).toEqual({ command, code: 1 });
      const payload = oneJsonObject(run.stdout);
      expect(String(payload.error)).toContain("unknown flag");
      expect(String(payload.error)).toContain(command);
    }
  });

  test("a typo on net cannot run the default DNS flush", async () => {
    const run = await box.run(["net", "--bogus", "--json"]);
    expect(run.code).toBe(1);
    expect(String(oneJsonObject(run.stdout).error)).toContain("unknown flag");
  });

  test("--help wins over running the command", async () => {
    const run = await box.run(["scan", "--help"]);
    expect(run.code).toBe(0);
    expect(run.stdout).toContain("dustless");
    expect(run.stdout).not.toContain('"findings"');
  });

  test("doctor --json and doctor agree on the exit code", async () => {
    const json = await box.run(["doctor", "--json"]);
    const human = await box.run(["doctor"]);
    expect(json.code).toBe(human.code);
  });
});