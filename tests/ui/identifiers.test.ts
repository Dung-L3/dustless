import { describe, expect, test } from "bun:test";
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";

const REPO = join(import.meta.dir, "..", "..");
const VIEWS = join(REPO, "apps", "dustless-mac", "Sources", "DustlessApp");
const UI_TESTS = join(REPO, "tests", "ui");

async function filesWithExtension(root: string, extension: string): Promise<string[]> {
  const entries = await readdir(root, { withFileTypes: true });
  const found: string[] = [];
  for (const entry of entries) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) {
      found.push(...(await filesWithExtension(path, extension)));
    } else if (entry.name.endsWith(extension)) {
      found.push(path);
    }
  }
  return found.sort();
}

function sourceIdentifiers(text: string): string[] {
  const found: string[] = [];
  const literal = /\.accessibilityIdentifier\(\s*"([^"]+)"\s*\)/g;
  const axID = /\baxID\(\s*"([^"]+)"\s*\)/g;
  const axIDArgument = /\b\w*[Ii]dentifier:\s*"([^"]+)"/g;
  for (const pattern of [literal, axID, axIDArgument]) {
    for (const match of text.matchAll(pattern)) {
      found.push(match[1]!);
    }
  }
  return found;
}

function usedIdentifiers(text: string): string[] {
  const found: string[] = [];
  const template = /\.(?:find|press|click|exists|waitGone)\(\s*`([^`]*)`/g;
  const literal = /\.(?:find|press|click|exists|waitGone)\(\s*"([^"]*)"/g;
  for (const match of text.matchAll(template)) {
    found.push(match[1]!.replace(/\$\{[^}]*\}/g, "\u0000"));
  }
  for (const match of text.matchAll(literal)) {
    found.push(match[1]!);
  }
  return found;
}

function prefixOf(identifier: string): string {
  const at = identifier.indexOf("\\(");
  return at === -1 ? identifier : identifier.slice(0, at);
}

function matches(source: string, used: string): boolean {
  if (source === used) return true;
  const prefix = prefixOf(source);
  if (prefix === source) return false;
  return used.startsWith(prefix);
}

const declaredIdentifiers = await (async () => {
  const files = await filesWithExtension(VIEWS, ".swift");
  const declared: string[] = [];
  for (const file of files) declared.push(...sourceIdentifiers(await readFile(file, "utf8")));
  return declared;
})();

const identifiersUsedByTests = await (async () => {
  const files = await filesWithExtension(UI_TESTS, ".ts");
  const used: string[] = [];
  for (const file of files) used.push(...usedIdentifiers(await readFile(file, "utf8")));
  return used;
})();

describe("accessibility identifiers", () => {
  test("every identifier a test uses exists in the app", () => {
    expect(identifiersUsedByTests.length).toBeGreaterThan(20);
    const unknown = identifiersUsedByTests.filter(
      (id) => !declaredIdentifiers.some((source) => matches(source, id)),
    );
    expect(unknown).toEqual([]);
  });

  test("the identifiers no test uses are reported", () => {
    const unused = declaredIdentifiers.filter(
      (id) => !identifiersUsedByTests.some((candidate) => matches(id, candidate)),
    );
    console.log(
      `accessibility identifiers declared in the app: ${declaredIdentifiers.length}, ` +
        `used by a test: ${declaredIdentifiers.length - unused.length}, ` +
        `not used by any test: ${unused.length}`,
    );
    for (const id of unused) console.log(`  unused identifier: ${id}`);
    expect(Array.isArray(unused)).toBe(true);
  });

  test("an identifier that is declared twice is reported", async () => {
    const files = await filesWithExtension(VIEWS, ".swift");
    const seen = new Map<string, number>();
    for (const file of files) {
      for (const id of sourceIdentifiers(await readFile(file, "utf8"))) {
        seen.set(id, (seen.get(id) ?? 0) + 1);
      }
    }
    const duplicated = [...seen.entries()].filter(([, count]) => count > 1).map(([id]) => id);
    console.log(`accessibility identifiers declared more than once: ${duplicated.length}`);
    for (const id of duplicated) console.log(`  duplicated identifier: ${id}`);
    expect(Array.isArray(duplicated)).toBe(true);
  });
});
