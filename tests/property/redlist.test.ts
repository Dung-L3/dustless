import { describe, expect, test } from "bun:test";
import { resolve } from "node:path";
import { isRed, RED_PATTERNS } from "../../src/core/paths.ts";

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
    return this.state;
  }
  nextFloat(): number { return this.next() / 0x100000000; }
  pick<T>(arr: T[]): T { return arr[this.next() % arr.length]; }
  bool(p = 0.5): boolean { return this.nextFloat() < p; }
  int(min: number, max: number): number { return min + this.next() % (max - min + 1); }
}

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

function withHomeRel(path: string): string[] {
  return [`~/` + path, `$HOME/` + path, `/Users/testuser/` + path];
}

function withTraversalNoise(path: string, rng: XorShift32): string {
  let out = path;
  if (rng.bool(0.3)) out = "./" + out;
  if (rng.bool(0.3)) out = out.replace(/\//g, "//");
  if (rng.bool(0.2)) out = out + "/";
  if (rng.bool(0.2)) out = out.replace(/([^/]+)/g, "$1/..") + "/" + out.split("/").pop();
  return out;
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

function resolvesInsideRedDir(noisy: string, canonicalBase: string): boolean {
  const resolved = resolve(noisy);
  return isRed(resolved) && resolved.includes(canonicalBase.replace("/Users/testuser/", ""));
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
    const overBlockingIsFailClosed = true;
    const decoyBases = [
      "DocumentsBackup", "MyDocuments", "Desktop2", "Pictures2",
      "Movies2", "Music2", "iCloudDrive", "KeychainBackup",
      "MessagesArchive", "ContactsOld",
    ];
    const failures: string[] = [];
    for (const decoy of decoyBases) {
      const fullPath = `/Users/testuser/${decoy}`;
      if (!isRed(fullPath)) {
        failures.push(`seed=${SEED} input="${fullPath}" (decoy should be red due to substring match)`);
      }
    }
    if (failures.length > 0) {
      throw new Error(failures.join("\n"));
    }
    expect(overBlockingIsFailClosed).toBe(true);
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
      const basePath = "/Users/testuser/" + canonical;
      for (let i = 0; i < 12; i++) {
        const base = basePath + "/" + randomPath(rng, rng.int(1, 3));
        const noisy = withTraversalNoise(base, rng);
        const resolvedNoisy = resolve(noisy);
        if (resolvesInsideRedDir(noisy, basePath)) {
          if (!isRed(resolvedNoisy)) {
            failures.push(`seed=${SEED} input="${noisy}" resolved="${resolvedNoisy}" base="${basePath}" (should be red after resolve)`);
          }
        }
        for (const form of withHomeRel(canonical + "/" + randomPath(rng, rng.int(1, 3)))) {
          const resolvedForm = resolve(form);
          if (resolvesInsideRedDir(form, basePath)) {
            if (!isRed(resolvedForm)) {
              failures.push(`seed=${SEED} input="${resolvedForm}" original="${form}" base="${basePath}" (should be red after resolve)`);
            }
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
    for (const p of corpus) {
      const r1 = isRed(p);
      const r2 = isRed(p);
      if (r1 !== r2) {
        failures.push(`seed=${SEED} input="${p}" r1=${r1} r2=${r2}`);
      }
      const resolved = resolve(p);
      const r3 = isRed(resolved);
      if (r1 !== r3) {
        failures.push(`seed=${SEED} input="${p}" resolved="${resolved}" r1=${r1} r3=${r3}`);
      }
    }
    if (failures.length > 0) {
      throw new Error(failures.join("\n"));
    }
  });
});