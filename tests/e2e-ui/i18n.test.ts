import { describe, expect, test } from "bun:test";
import { LANGUAGES, STRINGS, createTranslator } from "../../src/ui/public/i18n.js";
import { readUiAsset } from "./dom-stub.ts";

const CODES = LANGUAGES.map((lang) => lang.code);
const REFERENCE = "en";
const EN = STRINGS[REFERENCE] as Record<string, string>;

const TERNARY_KEYS = [
  "scanning", "working", "scanningHint", "workingHint",
  "green", "yellow", "blocked", "blockedNotice",
  "itemOne", "itemMany",
];

const literals = (text: string, re: RegExp): string[] =>
  [...new Set([...text.matchAll(re)].map((m) => m[1]).filter((v): v is string => typeof v === "string"))];

async function html(): Promise<string> {
  return await readUiAsset("index.html");
}

describe("i18n tables", () => {
  test("every language is registered exactly once and has a table", () => {
    expect(new Set(CODES).size).toBe(CODES.length);
    for (const code of CODES) expect(STRINGS[code]).toBeDefined();
    expect([...Object.keys(STRINGS)].sort()).toEqual([...CODES].sort());
  });

  test("vi, en and zh expose the identical key set", () => {
    const reference = Object.keys(EN).sort();
    for (const code of CODES) {
      expect({ code, keys: Object.keys(STRINGS[code] ?? {}).sort() }).toEqual({ code, keys: reference });
    }
  });

  test("no translation is empty or whitespace", () => {
    for (const code of CODES) {
      const table = STRINGS[code] ?? {};
      for (const [key, value] of Object.entries(table)) {
        expect(`${code}/${key}:${value.trim()}`).toBe(`${code}/${key}:${value.trim()}`);
        expect(value.trim().length).toBeGreaterThan(0);
      }
    }
  });

  test("no translated string is left as its own raw key", () => {
    const raw: { code: string; key: string }[] = [];
    for (const code of CODES.filter((lang) => lang !== REFERENCE)) {
      for (const [key, value] of Object.entries(STRINGS[code] ?? {})) {
        if (value === key) raw.push({ code, key });
      }
    }
    expect(raw).toEqual([]);
  });

  test("every language keeps the English placeholder set for a key", () => {
    const holes = (text: string): string[] => (text.match(/\{(\w+)\}/g) ?? []).sort();
    for (const code of CODES) {
      for (const [key, value] of Object.entries(STRINGS[code] ?? {})) {
        expect({ code, key, holes: holes(value) }).toEqual({ code, key, holes: holes(EN[key] ?? "") });
      }
    }
  });

  test("vi and zh differ from English, so the switch is not a no-op", () => {
    const template = (text: string): boolean => text.replace(/\{[^}]*\}/gu, "").replace(/[^\p{L}]/gu, "").length === 0;
    const copied: { code: string; key: string }[] = [];
    for (const code of CODES.filter((lang) => lang !== REFERENCE)) {
      const table = STRINGS[code] ?? {};
      for (const key of Object.keys(EN)) {
        if (table[key] === EN[key] && !template(EN[key] ?? "")) copied.push({ code, key });
      }
    }
    expect(copied).toEqual([]);
  });
});

describe("i18n keys used by the UI", () => {
  test("every data-i18n key in index.html exists in every language", async () => {
    const keys = literals(await html(), /data-i18n="([a-zA-Z0-9_]+)"/g);
    expect(keys.length).toBeGreaterThan(20);
    for (const code of CODES) {
      for (const key of keys) expect(STRINGS[code]?.[key]).toBeDefined();
    }
  });

  test("every t(\"key\") literal in app.js exists in every language", async () => {
    const keys = literals(await readUiAsset("app.js"), /[^a-zA-Z0-9_$.]t\(\s*"([a-zA-Z0-9_]+)"/g);
    expect(keys.length).toBeGreaterThan(5);
    for (const code of CODES) {
      for (const key of [...keys, ...TERNARY_KEYS]) expect(STRINGS[code]?.[key]).toBeDefined();
    }
  });

  test("unknown locale falls back to English instead of throwing", () => {
    const t = createTranslator("fr");
    expect(t("cleanNow")).toBe(EN["cleanNow"] ?? "");
  });

  test("unknown key falls back to English, then to the key itself", () => {
    const t = createTranslator("vi");
    expect(t("noSuchKey")).toBe("noSuchKey");
    expect(t("noSuchKey", { a: 1 })).toBe("noSuchKey");
  });

  test("interpolation fills every placeholder", () => {
    const t = createTranslator("en");
    expect(t("foundMeta", { items: 7, rules: 3, ms: "412ms" })).toBe("7 items across 3 rules · scanned in 412ms");
    expect(t("itemMany", { n: 4 })).toBe("4 items");
  });

  test("a missing placeholder leaves the raw token visible", () => {
    const t = createTranslator("en");
    expect(t("foundMeta", { items: 7, rules: 3 })).toContain("{ms}");
  });
});