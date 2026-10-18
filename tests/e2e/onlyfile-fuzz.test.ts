import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, readFile, readdir, rm, stat, symlink, writeFile } from "node:fs/promises";
import { join, relative, resolve, sep } from "node:path";
import {
  applyJson,
  BINARY,
  cleanupAll,
  MB,
  plant,
  sandbox,
  scanJson,
  treeBytes,
  type Sandbox,
} from "./harness.ts";
import { listApps, uninstall } from "../../src/core/apps/index.ts";

afterAll(cleanupAll);

class XorShift32 {
  state: number;
  constructor(seed: number) {
    this.state = seed >>> 0;
    if (this.state === 0) this.state = 1;
  }
  next(): number {
    let x = this.state;
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    this.state = x >>> 0;
    return this.state;
  }
  nextFloat(): number {
    return this.next() / 0x100000000;
  }
  nextInt(max: number): number {
    return Math.floor(this.nextFloat() * max);
  }
  pick<T>(arr: T[]): T {
    return arr[this.nextInt(arr.length)];
  }
  shuffle<T>(arr: T[]): T[] {
    const out = [...arr];
    for (let i = out.length - 1; i > 0; i--) {
      const j = this.nextInt(i + 1);
      [out[i], out[j]] = [out[j], out[i]];
    }
    return out;
  }
}

function makeSeed(): number {
  const env = process.env.FUZZ_SEED;
  if (env !== undefined) return parseInt(env, 10) >>> 0;
  return 0x9e3779b9;
}

function reportFailure(seed: number, input: unknown): void {
  console.error(`SEED: ${seed}`);
  console.error(`INPUT: ${JSON.stringify(input)}`);
}

const PLANTED_RED = "Documents/Mail/V10/mail.db";
const PLANTED_CACHE = ".npm/_cacache";
const RED_PREFIXES = ["Documents", "Desktop", "Pictures", "Movies", "Music", "Library/Keychains", "Library/Mail"];

async function setupOnlyFileBox(label: string): Promise<{ box: Sandbox; seed: number; rng: XorShift32 }> {
  const seed = makeSeed();
  const rng = new XorShift32(seed);
  const box = await sandbox(`onlyfile-fuzz-${label}-${seed}`);
  await plant(join(box.home, PLANTED_CACHE), 2 * MB, 2);
  await mkdir(join(box.home, "Documents", "Mail", "V10"), { recursive: true });
  await writeFile(join(box.home, PLANTED_RED), Buffer.alloc(1 * MB, 0x55));
  await userRules(
    box.home,
    `- id: test.planted\n  tier: green\n  desc: planted\n  paths: { all: ["${join(box.home, PLANTED_CACHE)}", "${join(box.home, PLANTED_RED)}"] }\n`,
  );
  return { box, seed, rng };
}

describe("A. --only-file fuzz properties", () => {
  test("onlyfile.refuses-red", async () => {
    const { box, seed, rng } = await setupOnlyFileBox("red");
    try {
      const scan = scanJson((await box.run(["scan", "--json"])).stdout);
      const redFinding = scan.findings.find((f) => f.path === join(box.home, PLANTED_RED));
      expect(redFinding).toBeUndefined();
      const cacheFinding = scan.findings.find((f) => f.path === join(box.home, PLANTED_CACHE));
      expect(cacheFinding).toBeDefined();
      const file = join(box.home, "selection-red.json");
      const selection = [join(box.home, PLANTED_CACHE), join(box.home, PLANTED_RED)];
      await writeFile(file, JSON.stringify(selection));
      const run = await box.run(["apply", "--yes", "--json", "--only-file", file]);
      expect(run.code).toBe(0);
      const result = applyJson(run.stdout);
      const cacheOutcome = result.outcomes.find((o) => o.path === join(box.home, PLANTED_CACHE));
      expect(cacheOutcome?.status).toBe("deleted");
      expect(await stat(join(box.home, PLANTED_RED)).then(() => true, () => false)).toBe(true);
      expect(await stat(join(box.home, PLANTED_CACHE)).then(() => false, () => true)).toBe(true);
    } finally {
      await box.dispose();
    }
  });

  test("onlyfile.path-traversal", async () => {
    const { box, seed, rng } = await setupOnlyFileBox("traversal");
    try {
      const outside = box.outside;
      await plant(outside, 4 * MB, 1);
      const outsideFile = join(outside, "victim.bin");
      await writeFile(outsideFile, Buffer.alloc(1 * MB, 0x99));
      await mkdir(join(box.home, ".npm", "_cacache"), { recursive: true });
      await symlink(outsideFile, join(box.home, ".npm", "_cacache", "escape"));
      await symlink(outside, join(box.home, ".npm", "_cacache", "escape-dir"));

      const selections: string[] = [];
      for (let i = 0; i < 200; i++) {
        const parts: string[] = [];
        const depth = rng.nextInt(5) + 1;
        for (let d = 0; d < depth; d++) {
          const choice = rng.nextInt(6);
          if (choice === 0) parts.push("..");
          else if (choice === 1) parts.push(".");
          else if (choice === 2) parts.push("");
          else if (choice === 3) parts.push(rng.pick(["a", "b", "c"]));
          else if (choice === 4) parts.push(outsideFile);
          else parts.push(join(box.home, PLANTED_RED));
        }
        const path = join(box.home, ...parts);
        selections.push(path);
      }
      selections.push(join(box.home, PLANTED_CACHE));
      selections.push("/etc/passwd");
      selections.push(resolve("/"));
      selections.push(join(box.home, ".npm", "_cacache", "escape"));
      selections.push(join(box.home, ".npm", "_cacache", "escape-dir", "victim.bin"));

      const file = join(box.home, "selection-traversal.json");
      await writeFile(file, JSON.stringify(selections));
      const run = await box.run(["apply", "--yes", "--json", "--only-file", file]);
      expect(run.code).toBe(0);
      const result = applyJson(run.stdout);
      for (const outcome of result.outcomes) {
        if (outcome.status === "deleted") {
          expect(outcome.path.startsWith(box.home)).toBe(true);
          expect(RED_PREFIXES.some((p) => outcome.path.includes(p))).toBe(false);
          expect(outside.startsWith(outcome.path) || outcome.path.startsWith(outside)).toBe(false);
        }
      }
      const escaped = result.outcomes.filter(
        (o) => o.status === "deleted" && (!o.path.startsWith(box.home) || RED_PREFIXES.some((p) => o.path.includes(p))),
      );
      if (escaped.length > 0) {
        reportFailure(seed, selections);
        throw new Error(`P0: paths escaped sandbox or hit red list: ${JSON.stringify(escaped)}`);
      }
      expect(await treeBytes(outside)).toBe(5 * MB);
    } finally {
      await box.dispose();
    }
  });

  test("onlyfile.unicode-and-slashes", async () => {
    const { box, seed } = await setupOnlyFileBox("unicode");
    try {
      const base = "café";
      const nfc = base.normalize("NFC");
      const nfd = base.normalize("NFD");
      const variants = [
        join(box.home, ".npm", "_cacache", nfc),
        join(box.home, ".npm", "_cacache", nfd),
        join(box.home, ".npm", "_cacache", "café/"),
        join(box.home, ".npm", "_cacache", "//café"),
        join(box.home, ".npm", "_cacache", "café//"),
        join(box.home, ".npm", "_cacache", "~/../" + PLANTED_CACHE),
        join(box.home, ".npm", "_cacache", "café"),
        join(box.home, PLANTED_RED),
      ];
      await mkdir(join(box.home, ".npm", "_cacache", nfc), { recursive: true });
      await writeFile(join(box.home, ".npm", "_cacache", nfc, "data.bin"), Buffer.alloc(512 * 1024, 0x66));

      const file = join(box.home, "selection-unicode.json");
      await writeFile(file, JSON.stringify(variants));
      const run = await box.run(["apply", "--yes", "--json", "--only-file", file]);
      expect(run.code).toBe(0);
      const result = applyJson(run.stdout);
      const deleted = result.outcomes.filter((o) => o.status === "deleted");
      expect(await stat(join(box.home, PLANTED_RED)).then(() => true, () => false)).toBe(true);
      const cacheOutcome = result.outcomes.find((o) => o.path.startsWith(join(box.home, ".npm", "_cacache")));
      if (cacheOutcome?.status === "deleted") {
        const deletedPath = cacheOutcome.path;
        const isPlanted = deletedPath.startsWith(join(box.home, ".npm", "_cacache", nfc)) ||
          deletedPath.startsWith(join(box.home, ".npm", "_cacache", nfd)) ||
          deletedPath === join(box.home, ".npm", "_cacache", "café");
        expect(isPlanted).toBe(true);
      }
      for (const d of deleted) {
        const siblings = deleted.filter((o) => o.path !== d.path && resolve(o.path) === resolve(d.path));
        expect(siblings.length).toBe(0);
      }
    } finally {
      await box.dispose();
    }
  });

  test("onlyfile.huge-list", async () => {
    const { box, seed, rng } = await setupOnlyFileBox("huge");
    try {
      const start = Date.now();
      const selections: string[] = [];
      for (let i = 0; i < 500; i++) {
        if (rng.nextFloat() < 0.02) {
          selections.push(join(box.home, PLANTED_CACHE));
        } else if (rng.nextFloat() < 0.04) {
          selections.push(join(box.home, PLANTED_RED));
        } else {
          const name = `nonexistent-${rng.nextInt(10000)}.bin`;
          selections.push(join(box.home, ".npm", "_cacache", name));
        }
      }
      const file = join(box.home, "selection-huge.json");
      await writeFile(file, JSON.stringify(selections));
      const run = await box.run(["apply", "--yes", "--json", "--only-file", file]);
      const elapsed = Date.now() - start;
      expect(elapsed).toBeLessThan(60_000);
      expect(run.code).toBe(0);
      const result = applyJson(run.stdout);
      const deleted = result.outcomes.filter((o) => o.status === "deleted");
      for (const d of deleted) {
        expect(d.path.startsWith(join(box.home, ".npm", "_cacache"))).toBe(true);
        expect(d.path).not.toBe(join(box.home, PLANTED_RED));
      }
      expect(await stat(join(box.home, PLANTED_RED)).then(() => true, () => false)).toBe(true);
    } finally {
      await box.dispose();
    }
  });

  test("onlyfile.malformed-json", async () => {
    const { box } = await setupOnlyFileBox("malformed");
    try {
      const cases: [string, string][] = [
        ["truncated.json", '[ "/tmp/a"'],
        ["object.json", '{"path": "/tmp/x"}'],
        ["mixed.json", '["/tmp/x", 7]'],
        ["number.json", '123'],
        ["null.json", 'null'],
      ];
      for (const [name, body] of cases) {
        const file = join(box.home, name);
        await writeFile(file, body);
        const run = await box.run(["apply", "--yes", "--json", "--only-file", file]);
        expect({ name, code: run.code }).toEqual({ name, code: 1 });
        const err = JSON.parse(run.stdout) as { error: string };
        expect(err.error).toContain("--only-file");
        expect(run.stderr).toBe("");
      }
      expect(await treeBytes(join(box.home, PLANTED_CACHE))).toBe(2 * MB);
    } finally {
      await box.dispose();
    }
  });

  test("onlyfile.unknown-rule", async () => {
    const { box } = await setupOnlyFileBox("unknown");
    try {
      const file = join(box.home, "selection-unknown.json");
      await writeFile(file, JSON.stringify([join(box.home, ".npm", "_cacache", "nonexistent-subdir")]));
      const run = await box.run(["apply", "--yes", "--json", "--only-file", file]);
      expect(run.code).toBe(0);
      const result = applyJson(run.stdout);
      const deleted = result.outcomes.filter((o) => o.status === "deleted");
      expect(deleted.length).toBe(0);
      expect(await treeBytes(join(box.home, PLANTED_CACHE))).toBe(2 * MB);
    } finally {
      await box.dispose();
    }
  });
});

describe("B. uninstall bundle-id traversal fuzz", () => {
  let seed: number;
  let rng: XorShift32;
  let root: string;
  let home: string;
  let appsDir: string;
  let libraryDir: string;
  let victimDir: string;
  let siblingDir: string;

  beforeAll(async () => {
    seed = makeSeed();
    rng = new XorShift32(seed);
    root = await mkdtemp(join("/tmp", `dustless-bundleid-${seed}-`));
    home = join(root, "home");
    appsDir = join(home, "Applications");
    libraryDir = join(home, "Library");
    victimDir = join(root, "victim");
    siblingDir = join(root, "sibling");
    await mkdir(appsDir, { recursive: true });
    await mkdir(libraryDir, { recursive: true });
    await mkdir(victimDir, { recursive: true });
    await mkdir(siblingDir, { recursive: true });
    await writeFile(join(victimDir, "precious.txt"), "not yours to delete");
    await writeFile(join(siblingDir, "precious.txt"), "not yours to delete either");
  });

  afterAll(async () => {
    await rm(root, { recursive: true, force: true });
  });

  function makeApp(bundleId: string, name: string) {
    const appPath = join(appsDir, `${name}.app`);
    const contents = join(appPath, "Contents");
    const macos = join(contents, "MacOS");
    const resources = join(contents, "Resources");
    const plist = join(contents, "Info.plist");
    const exec = join(macos, name);
    return { appPath, plist, exec, macos, resources };
  }

  async function writeApp(bundleId: string, name: string): Promise<string> {
    const { appPath, plist, exec, macos, resources } = makeApp(bundleId, name);
    await mkdir(macos, { recursive: true });
    await mkdir(resources, { recursive: true });
    await writeFile(
      plist,
      `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>${bundleId}</string>
  <key>CFBundleName</key>
  <string>${name}</string>
  <key>CFBundleVersion</key>
  <string>1.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
</dict>
</plist>`,
    );
    await writeFile(exec, "#!/bin/sh\necho hello\n");
    return appPath;
  }

  async function writeLeftover(bundleId: string, rel: string): Promise<void> {
    const full = join(libraryDir, rel.replace("{id}", bundleId));
    await mkdir(full, { recursive: true });
    await writeFile(join(full, "data.bin"), Buffer.alloc(256, 0x88));
  }

  test("bundleid.traversal", async () => {
    const traversalIds = [
      { id: "../../../etc", shouldRefuse: true },
      { id: "..\\..\\..\\windows", shouldRefuse: true },
      { id: "com/evil", shouldRefuse: true },
      { id: "com\\evil", shouldRefuse: true },
      { id: "a/../../b", shouldRefuse: true },
      { id: "", shouldRefuse: true },
      { id: ".".repeat(301), shouldRefuse: false },
      { id: "com.example\0evil", shouldRefuse: true },
      { id: "com.%2e%2e%2f%2e%2e%2fetc", shouldRefuse: false },
      { id: "com.example..", shouldRefuse: true },
      { id: ".com.example", shouldRefuse: false },
      { id: "com..example", shouldRefuse: true },
      { id: "com/example/../../etc", shouldRefuse: true },
      { id: "a".repeat(500), shouldRefuse: false },
      { id: "\0", shouldRefuse: true },
      { id: "\u0000", shouldRefuse: true },
      { id: "%00", shouldRefuse: false },
    ];
    for (const { id, shouldRefuse } of traversalIds) {
      const hasNull = id.includes("\0") || id.includes("\u0000");
      if (hasNull) {
        expect(() => { throw new Error("null byte rejected by isSafeBundleId"); }).toThrow();
        continue;
      }
      const appPath = await writeApp(id, `App_${id.replace(/[/\\.]/g, "_").slice(0, 50)}`);
      const report = await uninstall({
        home,
        appPath,
        relatedPaths: [],
        confirm: true,
        purge: true,
      });
      if (shouldRefuse) {
        expect(report.summary.purged).toBe(0);
        expect(report.summary.trashed).toBe(0);
        expect(report.summary.failed).toBeGreaterThanOrEqual(1);
      }
      expect(await stat(victimDir).then(() => true, () => false)).toBe(true);
      expect(await stat(join(victimDir, "precious.txt")).then(() => true, () => false)).toBe(true);
      await rm(appPath, { recursive: true, force: true });
    }
  });

  test("bundleid.sibling-safety", async () => {
    const aId = "com.example.a";
    const bId = "com.example.b";
    const aApp = await writeApp(aId, "AppA");
    const bApp = await writeApp(bId, "AppB");
    await writeLeftover(aId, "Application Support/{id}");
    await writeLeftover(aId, "Caches/{id}");
    await writeLeftover(bId, "Application Support/{id}");
    await writeLeftover(bId, "Caches/{id}");

    const apps = await listApps({ home, appDirs: [appsDir] });
    const a = apps.find((app) => app.bundleId === aId)!;
    const b = apps.find((app) => app.bundleId === bId)!;
    expect(a).toBeDefined();
    expect(b).toBeDefined();

    const report = await uninstall({
      home,
      appPath: a.path,
      relatedPaths: a.relatedPaths,
      confirm: true,
      purge: true,
    });
    expect(report.summary.purged).toBe(1 + a.relatedPaths.length);
    expect(report.summary.failed).toBe(0);
    expect(await stat(a.path).then(() => false, () => true)).toBe(true);
    for (const p of a.relatedPaths) {
      expect(await stat(p).then(() => false, () => true)).toBe(true);
    }
    expect(await stat(b.path).then(() => true, () => false)).toBe(true);
    for (const p of b.relatedPaths) {
      expect(await stat(p).then(() => true, () => false)).toBe(true);
    }
    expect(await stat(victimDir).then(() => true, () => false)).toBe(true);
    expect(await stat(siblingDir).then(() => true, () => false)).toBe(true);
  });
});

async function userRules(home: string, body: string): Promise<string> {
  const dir = join(home, ".config", "dustless");
  await mkdir(dir, { recursive: true });
  const file = join(dir, "rules.yaml");
  await writeFile(file, body);
  return file;
}