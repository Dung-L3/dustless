import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { LANGUAGES, STRINGS } from "../src/ui/public/i18n.js";

// The native app must speak the same vocabulary as the web UI, not a
// near-enough paraphrase. This parses the Swift tables and fails on any drift,
// so the two surfaces can never quietly diverge.
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
const CODES = LANGUAGES.map((lang: { code: string }) => lang.code);
const src = await readFile(SWIFT, "utf8");

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

const tables: Record<string, Map<string, string>> = {};
for (const code of CODES) tables[code] = entries(code);

describe("native app i18n mirrors i18n.js", () => {
  test("every language has a substantial table", () => {
    for (const code of CODES) expect({ code, size: tables[code]!.size > 80 }).toEqual({ code, size: true });
  });

  test("vi, en and zh expose the identical key set", () => {
    const reference = [...tables.en!.keys()].sort();
    for (const code of CODES) {
      expect({ code, keys: [...tables[code]!.keys()].sort() }).toEqual({ code, keys: reference });
    }
  });

  test("every i18n.js key exists in the Swift table with the same value", () => {
    const missing: string[] = [];
    const mismatched: string[] = [];
    for (const code of CODES) {
      const web = (STRINGS[code] ?? {}) as Record<string, string>;
      for (const [key, value] of Object.entries(web)) {
        const local = tables[code]!.get(key);
        if (local === undefined) missing.push(`${code}/${key}`);
        else if (local !== value) {
          mismatched.push(`${code}/${key}: web=${JSON.stringify(value)} swift=${JSON.stringify(local)}`);
        }
      }
    }
    expect({ missing, mismatched }).toEqual({ missing: [], mismatched: [] });
  });

  test("no Swift translation is empty or whitespace", () => {
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
        expect({ code, key, holes: holes(value) }).toEqual({ code, key, holes: holes(tables.en!.get(key) ?? "") });
      }
    }
  });
});
