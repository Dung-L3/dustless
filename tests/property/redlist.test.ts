import { describe, expect, test } from "bun:test";
import { resolve } from "node:path";
import { isRed } from "../../src/core/paths.ts";

const SEED = Number(process.env.FUZZ_SEED ?? 123456789);

class XorShift32 {
  private state: number;
  constructor(seed: number) { this.state = seed >>> 0; }
  next(): number {
    let x = this.state;
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    this.state = x >>> 0;
    return x;
  }
  nextFloat(): number { return this.next() / 0x100000000; }
  pick<T>(arr: T[]): T { return arr[this.next() % arr.length] as T; }
  bool(p = 0.5): boolean { return this.nextFloat() < p; }
  int(min: number, max: number): number { return min + this.next() % (max - min + 1); }
}

const HOME_ROOT = "/Users/testuser";

const ANYWHERE_CANONICAL = [
  "Documents", "Desktop", "Pictures", "Movies", "Music",
  "Contacts", "Reminders", "Calendar", "Finance", "Passes",
  "Keynotes", "Messages", "iCloud", "Keychain", "Keychains",
  "Application Support/com.apple.Photos",
  "Application Support/com.apple.MobileSync",
  "Application Support/com.apple.Notes",
  "Application Support/com.apple.Trial",
];

const SUFFIX_CANONICAL = [
  { name: "Mail", path: "Mail" },
  { name: "Mail.v2", path: "Mail.v2" },
  { name: "Preferences", path: "Preferences" },
  { name: "Git", path: ".git" },
  { name: "GitSlash", path: ".git/" },
  { name: "Wal", path: "data-wal" },
  { name: "Shm", path: "data-shm" },
];

const ALL_CANONICAL = [...ANYWHERE_CANONICAL, ...SUFFIX_CANONICAL.map(c => c.path)];

const TREE_CANONICAL: string[] = [
  ...ANYWHERE_CANONICAL,
  "Mail", "Mail.v2", ".git",
];

const SUFFIX_ONLY_CANONICAL: string[] = ["Preferences", "data-wal", "data-shm"];

const SEGMENTS = [
  "a", "b", "c", "d", "e", "f", "g", "h", "i", "j",
  "cache", "logs", "tmp", "data", "config", "build", "dist", "node_modules",
  "Library", "Application Support", "Caches", "Preferences",
];

function randomCase(str: string, rng: XorShift32): string {
  return str.split("").map(ch => rng.bool(0.5) ? ch.toUpperCase() : ch.toLowerCase()).join("");
}

function randomPath(rng: XorShift32, depth: number): string {
  const parts: string[] = [];
  for (let i = 0; i < depth; i++) {
    parts.push(rng.pick(SEGMENTS));
  }
  return parts.join("/");
}

function unixified(path: string): string {
  return path.replace(/[\\/]+/g, "/");
}

function expandTesterHome(path: string): string {
  if (path.startsWith("~/")) return HOME_ROOT + path.slice(1);
  if (path.startsWith("$HOME/")) return HOME_ROOT + path.slice(6);
  return path;
}

function redRoots(): { trees: string[]; exact: string[] } {
  return {
    trees: TREE_CANONICAL.map(canonical => resolve(HOME_ROOT + "/" + canonical)),
    exact: SUFFIX_ONLY_CANONICAL.map(canonical => resolve(HOME_ROOT + "/" + canonical)),
  };
}

function insideRoot(resolved: string, root: string): boolean {
  return resolved === root || resolved.startsWith(root + "/");
}

function noiseSpecResolved(form: string): string {
  return resolve(expandTesterHome(unixified(form)));
}

function expectsRed(form: string): boolean {
  const resolved = noiseSpecResolved(form);
  const { trees, exact } = redRoots();
  return trees.some(root => insideRoot(resolved, root)) || exact.some(root => resolved === root);
}

function noisyForms(dir: string): string[] {
  const backslashForm = dir.replace(/\//g, "\\");
  const tripwireForm = dir.replace(/^\/Users\/testuser/, "/Users/testuser/..");
  return [
    dir,
    "/." + dir,
    dir.replace(/\//g, "//"),
    backslashForm,
    dir + "/",
    dir + "//",
    tripwireForm,
    "~/" + dir.slice(HOME_ROOT.length + 1),
    "$HOME/" + dir.slice(HOME_ROOT.length + 1),
    "~/" + dir.slice(HOME_ROOT.length + 1).replace(/\//g, "//"),
    "$HOME/" + dir.slice(HOME_ROOT.length + 1).replace(/\//g, "\\"),
  ];
}

function noiseVariants(path: string): string[] {
  return [
    path + "/",
    path + "//",
    path.replace(/\//g, "//"),
    path.replace(/\//g, "\\"),
    "/." + path,
  ];
}

function testPathVariants(base: string, rng: XorShift32, count: number): string[] {
  const variants: string[] = [];
  for (let i = 0; i < count; i++) {
    const prefix = randomPath(rng, rng.int(1, 3));
    const suffix = randomPath(rng, rng.int(1, 3));
    variants.push(`/Users/testuser/${prefix}/${base}/${suffix}`);
  }
  return variants;
}

describe("redlist.property", () => {
  test("redlist.canonicity", () => {
    const rng = new XorShift32(SEED + 1);
    let generated = 0;
    for (const canonical of ALL_CANONICAL) {
      const fullPath = "/Users/testuser/" + canonical;
      if (!isRed(fullPath)) {
        throw new Error(`FAIL seed=${SEED} input="${fullPath}" canonical="${canonical}"`);
      }
      for (let i = 0; i < 8; i++) {
        const variant = randomCase(fullPath, rng);
        if (!isRed(variant)) {
          throw new Error(`FAIL seed=${SEED} input="${variant}" canonical="${canonical}"`);
        }
        generated++;
      }
    }
    expect(generated).toBeGreaterThanOrEqual(200);
  });

  test("redlist.over-blocking-is-accepted", () => {
    const decoyBases = [
      "DocumentsBackup", "MyDocuments", "Desktop2", "Pictures2",
      "Movies2", "Music2", "iCloudDrive", "KeychainBackup",
      "MessagesArchive", "ContactsOld",
    ];
    const failures: string[] = [];
    for (const decoy of decoyBases) {
      const base = `/Users/testuser/${decoy}`;
      for (const probe of [base, `${base}/`, `${base}/nested/file.db`]) {
        if (!isRed(probe)) {
          failures.push(`seed=${SEED} input="${probe}" (over-protective substring decoy must be red, including nested depth)`);
        }
      }
    }
    if (failures.length > 0) {
      throw new Error(failures.join("\n"));
    }
  });

  test("redlist.subset-superset", () => {
    const rng = new XorShift32(SEED + 2);
    const failures: string[] = [];
    for (const canonical of ANYWHERE_CANONICAL) {
      const variants = testPathVariants(canonical, rng, 20);
      for (const v of variants) {
        if (!isRed(v)) {
          failures.push(`seed=${SEED} input="${v}" canonical="${canonical}" (anywhere pattern should match mid-path)`);
        }
      }
    }
    for (const sc of SUFFIX_CANONICAL) {
      const basePath = `/Users/testuser/${sc.path}`;
      if (!isRed(basePath)) {
        failures.push(`seed=${SEED} input="${basePath}" canonical="${sc.path}" (canonical suffix pattern not red)`);
      }
      for (let i = 0; i < 10; i++) {
        const prefix = randomPath(rng, rng.int(1, 3));
        const extended = `/Users/testuser/${prefix}/${sc.path}`;
        if (!isRed(extended)) {
          failures.push(`seed=${SEED} input="${extended}" canonical="${sc.path}" (prefix should preserve suffix match)`);
        }
      }
    }
    if (failures.length > 0) {
      throw new Error(failures.join("\n"));
    }
  });

  test("redlist.nesting-and-segments", () => {
    const rng = new XorShift32(SEED + 3);
    const failures: string[] = [];
    for (const canonical of ANYWHERE_CANONICAL) {
      const basePath = "/Users/testuser/" + canonical;
      if (!isRed(basePath)) {
        failures.push(`seed=${SEED} input="${basePath}" (canonical not red)`);
        continue;
      }
      for (let i = 0; i < 10; i++) {
        const deep = basePath + "/" + randomPath(rng, rng.int(3, 5));
        if (!isRed(deep)) {
          failures.push(`seed=${SEED} input="${deep}" base="${basePath}" (nesting should be red)`);
        }
      }
      const withTrailing = basePath + "/";
      if (!isRed(withTrailing)) {
        failures.push(`seed=${SEED} input="${withTrailing}" base="${basePath}" (trailing slash should be red)`);
      }
      const withDupSlashes = basePath.replace(/\//g, "//");
      if (!isRed(withDupSlashes)) {
        failures.push(`seed=${SEED} input="${withDupSlashes}" base="${basePath}" (duplicated slashes should be red)`);
      }
    }
    for (const sc of SUFFIX_CANONICAL) {
      const basePath = "/Users/testuser/" + sc.path;
      if (!isRed(basePath)) {
        failures.push(`seed=${SEED} input="${basePath}" (canonical suffix not red)`);
      }
      const withTrailing = basePath + "/";
      if (!isRed(withTrailing)) {
        failures.push(`seed=${SEED} input="${withTrailing}" base="${basePath}" (trailing slash must not escape the red list)`);
      }
    }
    if (failures.length > 0) {
      throw new Error(failures.join("\n"));
    }
  });

  test("redlist.evasion-by-noise-resolve-normalisation", () => {
    const rng = new XorShift32(SEED + 4);
    const failures: string[] = [];
    for (const canonical of ALL_CANONICAL) {
      const root = HOME_ROOT + "/" + canonical;
      for (let i = 0; i < 12; i++) {
        const dir = root + "/" + randomPath(rng, rng.int(1, 3));
        for (const noisy of noisyForms(dir)) {
          if (!expectsRed(noisy)) continue;
          const specResolved = noiseSpecResolved(noisy);
          if (!isRed(noisy)) {
            failures.push(`seed=${SEED} input="${noisy}" base="${root}" (noisy form denotes a path inside a canonical red directory and must be red without any normalisation)`);
          }
          if (!isRed(specResolved)) {
            failures.push(`seed=${SEED} input="${noisy}" specResolved="${specResolved}" base="${root}" (unixify + node:path resolution lands inside a canonical red directory and must be red)`);
          }
        }
      }
    }
    if (failures.length > 0) {
      throw new Error(failures.join("\n"));
    }
  });

  test("redlist.idempotence", () => {
    const rng = new XorShift32(SEED + 5);
    const corpus: string[] = [];
    for (const canonical of ALL_CANONICAL) {
      corpus.push("/Users/testuser/" + canonical);
      corpus.push("/Users/testuser/" + canonical + "/" + randomPath(rng, 3));
    }
    for (let i = 0; i < 100; i++) {
      corpus.push("/Users/testuser/" + randomPath(rng, rng.int(1, 6)));
    }
    const decoyBases = [
      "DocumentsBackup", "MyDocuments", "Desktop2", "Pictures2",
      "Movies2", "Music2", "iCloudDrive", "KeychainBackup",
      "MessagesArchive", "ContactsOld",
    ];
    for (const decoy of decoyBases) {
      corpus.push("/Users/testuser/" + decoy);
      corpus.push("/Users/testuser/" + decoy + "/" + randomPath(rng, 2));
    }
    const failures: string[] = [];
    let noisyCompared = 0;
    for (const p of corpus) {
      const baseline = isRed(p);
      for (const variant of noiseVariants(p)) {
        if (resolve(unixified(variant)) !== resolve(p)) {
          failures.push(`seed=${SEED} variant "${variant}" independent of "${p}" (npm resolve mismatch, internal noise construction is wrong)`);
          continue;
        }
        noisyCompared++;
        const verdict = isRed(variant);
        if (verdict !== baseline) {
          failures.push(`seed=${SEED} input="${p}" variant="${variant}" baseline=${baseline} verdict=${verdict} (separator noise must not change the verdict)`);
        }
      }
    }
    expect(noisyCompared).toBeGreaterThanOrEqual(500);
    if (failures.length > 0) {
      throw new Error(failures.join("\n"));
    }
  });
});
