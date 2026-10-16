import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

// These three Swift tables are the only place the app's wording lives, so they
// are the single source. Nothing here parses another file: this parses
// Localization.swift directly and fails on any drift between the languages, so
// a translator adding a key to one table cannot quietly leave the others behind.
const SWIFT = join(
  import.meta.dir,
  "..",
  "apps",
  "dustless-mac",
  "Sources",
  "DustlessKit",
  "Model",
  "Localization.swift",
);
const src = await readFile(SWIFT, "utf8");

// Taken from the `Lang` enum rather than hardcoded, so adding a language to the
// app makes this test cover it instead of silently skipping it.
function languages(): string[] {
  const enumBody = /public enum Lang: String[^{]*\{([\s\S]*?)\n\}/.exec(src);
  expect(enumBody, "Lang enum not found in Localization.swift").not.toBeNull();
  return [...enumBody![1]!.matchAll(/^\s*case (\w+)\s*$/gm)].map((match) => match[1]!);
}

function block(lang: string): string {
  const marker = `static let ${lang}: [String: String] = [`;
  const at = src.indexOf(marker);
  expect(at, `Swift table for ${lang} is missing`).toBeGreaterThanOrEqual(0);
  const from = src.indexOf("[", at);
  const to = src.indexOf("\n    ]", from);
  expect(to, `Swift table for ${lang} is unterminated`).toBeGreaterThan(from);
  return src.slice(from, to);
}

function entries(lang: string): Map<string, string> {
  const found = [...block(lang).matchAll(/^\s*"([^"]+)": "([^"]*)",?$/gm)];
  return new Map(found.map((match) => [match[1]!, match[2]!]));
}

const CODES = languages();
const tables: Record<string, Map<string, string>> = {};
for (const code of CODES) tables[code] = entries(code);

describe("Localization.swift string tables", () => {
  test("the Lang enum and its string tables agree", () => {
    expect(CODES.length).toBeGreaterThanOrEqual(3);
    for (const code of CODES) {
      expect({ code, hasTable: tables[code] !== undefined }).toEqual({ code, hasTable: true });
    }
  });

  test("every language has a substantial table", () => {
    for (const code of CODES) expect({ code, size: tables[code]!.size > 80 }).toEqual({ code, size: true });
  });

  test("every language exposes the identical key set", () => {
    const reference = [...tables["en"]!.keys()].sort();
    for (const code of CODES) {
      expect({ code, keys: [...tables[code]!.keys()].sort() }).toEqual({ code, keys: reference });
    }
  });

  test("no translation is empty or whitespace", () => {
    const empty: string[] = [];
    for (const code of CODES) {
      for (const [key, value] of tables[code]!) {
        if (value.trim().length === 0) empty.push(`${code}/${key}`);
      }
    }
    expect(empty).toEqual([]);
  });

  test("placeholder sets match across languages", () => {
    const holes = (text: string): string[] => (text.match(/\{\w+\}/g) ?? []).sort();
    for (const code of CODES) {
      for (const [key, value] of tables[code]!) {
        expect({ code, key, holes: holes(value) }).toEqual({ code, key, holes: holes(tables["en"]!.get(key) ?? "") });
      }
    }
  });

  test("no key is declared twice in a table", () => {
    // A duplicate is a silent data loss: Swift keeps the last literal, and the
    // Map above would have quietly collapsed it into one entry.
    const dupes: string[] = [];
    for (const code of CODES) {
      const keys = [...block(code).matchAll(/^\s*"([^"]+)":/gm)].map((match) => match[1]!);
      const seen = new Set<string>();
      for (const key of keys) {
        if (seen.has(key)) dupes.push(`${code}/${key}`);
        seen.add(key);
      }
    }
    expect(dupes).toEqual([]);
  });
});
