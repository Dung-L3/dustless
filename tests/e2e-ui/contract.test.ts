import { describe, expect, test } from "bun:test";
import { type El, parseDocument, readUiAsset } from "./dom-stub.ts";

const TIERS = ["green", "yellow", "blocked"];
const INTERACTIVE = new Set(["button", "a", "input", "select", "textarea"]);
const SVG_NS = "http://www.w3.org/2000/svg";

const html = await readUiAsset("index.html");
const css = await readUiAsset("style.css");
const appJs = await readUiAsset("app.js");
const i18nJs = await readUiAsset("i18n.js");
const doc = parseDocument(html);

const all = (selector: string): El[] => doc.querySelectorAll(selector);
const id = (name: string): string | null => doc.getElementById(name)?.getAttribute("id") ?? null;

function name(el: El): string {
  const label = el.getAttribute("aria-label");
  if (label?.trim()) return label;
  const refs = el.getAttribute("aria-labelledby");
  if (refs) {
    const text = refs.split(/\s+/).map((ref) => doc.getElementById(ref)?.textContent ?? "").join(" ").trim();
    if (text) return text;
  }
  return el.getAttribute("title")?.trim() || el.textContent.trim();
}

const cssVar = (name: string): string => new RegExp(`${name}:\\s*(#[0-9a-fA-F]{3,8})`).exec(css)?.[1] ?? "";
const rgb = (hex: string): number[] => [1, 3, 5].map((at) => parseInt(hex.slice(at, at + 2), 16));

describe("app.js and index.html agree", () => {
  test("every id app.js looks up exists in the markup", () => {
    const wanted = new Set<string>();
    for (const match of appJs.matchAll(/getElementById\(\s*"([^"]+)"\s*\)/g)) wanted.add(match[1] ?? "");
    for (const match of appJs.matchAll(/\$\(\s*"([^"]+)"\s*\)/g)) wanted.add(match[1] ?? "");
    for (const match of appJs.matchAll(/\$\(\s*`([^`]+)`\s*\)/g)) {
      for (const tier of TIERS) wanted.add((match[1] ?? "").replaceAll("${tier}", tier));
    }
    expect(wanted.size).toBeGreaterThan(30);
    expect([...wanted].filter((name) => id(name) === null).sort()).toEqual([]);
  });

  test("every selector app.js queries targets markup it or the page produces", () => {
    const selectors = [...appJs.matchAll(/(?:querySelectorAll|querySelector|closest)\(\s*"([^"]+)"\s*\)/g)].map(
      (match) => match[1] ?? "",
    );
    expect(selectors.length).toBeGreaterThan(4);
    const fromHtml = new Set(all("[class]").flatMap((el) => el.className.split(/\s+/)));
    const fromApp = new Set(
      [...appJs.matchAll(/class:\s*"([^"]+)"/g)].flatMap((match) => (match[1] ?? "").split(/\s+/)),
    );
    const orphan: string[] = [];
    for (const selector of selectors) {
      for (const token of selector.match(/\.[\w-]+/g) ?? []) {
        const name = token.slice(1);
        if (!fromHtml.has(name) && !fromApp.has(name)) orphan.push(selector);
      }
    }
    expect([...new Set(orphan)]).toEqual([]);
  });

  test("every data-i18n node in the markup is a leaf app.js can overwrite", () => {
    const nested = all("[data-i18n]").filter((el) => el.children.length > 0);
    expect(nested.map((el) => el.getAttribute("data-i18n"))).toEqual([]);
  });

  test("app.js writes text, never markup, so a finding path cannot inject HTML", () => {
    expect(appJs).not.toMatch(/\.innerHTML\s*=/);
    expect(appJs).not.toMatch(/\bdocument\.write\b/);
    expect(appJs).not.toMatch(/\bnew Function\b|\beval\(/);
  });
});

describe("the page makes no off-origin requests", () => {
  test("every href and src stays on this origin", () => {
    const refs = [...html.matchAll(/\b(?:href|src)="([^"]*)"/g)].map((match) => match[1] ?? "");
    expect(refs.length).toBeGreaterThan(5);
    expect(refs.filter((ref) => !/^(#|data:|\/)/.test(ref))).toEqual([]);
  });

  test("the only absolute URLs are XML namespace identifiers, which are never fetched", async () => {
    for (const [file, text] of [
      ["index.html", html],
      ["style.css", css],
      ["app.js", appJs],
      ["i18n.js", i18nJs],
    ] as const) {
      const urls = [...new Set([...text.matchAll(/https?:\/\/[^\s"'`()<>]+/g)].map((match) => match[0]))];
      expect({ file, urls: urls.filter((url) => url !== SVG_NS) }).toEqual({
        file,
        urls: [],
      });
    }
  });

  test("style.css loads nothing but inline data images", () => {
    const stripped = css.replace(/url\(\s*(["'])data:[\s\S]*?\1\s*\)/g, "");
    expect({ remaining: stripped.match(/url\(/g) ?? [] }).toEqual({ remaining: [] });
  });

  test("the markup carries no inline script, handler or style, which the CSP forbids", () => {
    expect(html).not.toMatch(/<script(?![^>]*\ssrc=)/);
    expect(html).not.toMatch(/\son[a-z]+\s*=/i);
    expect(html).not.toMatch(/\sstyle="/i);
  });
});

describe("motion and colour", () => {
  test("prefers-reduced-motion is honoured in css and read by app.js", () => {
    const block = /@media\s*\(prefers-reduced-motion:\s*reduce\)\s*\{[\s\S]*?\n\}/.exec(css)?.[0] ?? "";
    expect(block).not.toBe("");
    expect(block).toContain("animation-duration");
    expect(block).toContain("transition-duration");
    const queried = /matchMedia\(\s*"([^"]+)"/.exec(appJs)?.[1] ?? "";
    expect(queried).toBe("(prefers-reduced-motion: reduce)");
  });

  test("the three tier colours are far enough apart to tell apart", () => {
    const pairs: { a: string; b: string; distance: number }[] = [];
    for (let i = 0; i < TIERS.length; i++) {
      for (let j = i + 1; j < TIERS.length; j++) {
        const a = rgb(cssVar(`--${TIERS[i]}`));
        const b = rgb(cssVar(`--${TIERS[j]}`));
        pairs.push({
          a: TIERS[i] ?? "",
          b: TIERS[j] ?? "",
          distance: Math.round(Math.hypot(a[0]! - b[0]!, a[1]! - b[1]!, a[2]! - b[2]!)),
        });
      }
    }
    expect(pairs).toHaveLength(3);
    for (const pair of pairs) expect(pair.distance).toBeGreaterThanOrEqual(80);
  });

  test("each tier card maps to its own colour variable", () => {
    for (const tier of TIERS) {
      expect(css).toContain(`[data-tier="${tier}"] { --tier: var(--${tier})`);
      expect(html).toContain(`data-tier="${tier}"`);
    }
    expect(all("#tiers article").length).toBe(3);
  });
});

describe("accessibility contracts in the static markup", () => {
  test("every interactive control has an accessible name", () => {
    const controls = all("*").filter(
      (el) => INTERACTIVE.has(el.tag) || el.hasAttribute("tabindex"),
    );
    expect(controls.length).toBeGreaterThan(5);
    expect(controls.filter((el) => name(el) === "").map((el) => `${el.tag}#${el.getAttribute("id") ?? ""}`)).toEqual([]);
  });

  test("every control that shows only an icon names itself with an attribute", () => {
    const iconOnly = all("button, a").filter((el) => el.textContent.trim() === "");
    expect(iconOnly.map((el) => el.outerHTML.slice(0, 80))).not.toContain("");
    expect(
      iconOnly
        .filter((el) => !el.hasAttribute("aria-label") && !el.hasAttribute("aria-labelledby"))
        .map((el) => el.outerHTML.slice(0, 80)),
    ).toEqual([]);
  });

  test("decorative svg is hidden from assistive tech, meaningful svg is named", () => {
    const exposed = all("svg").filter((el) => el.getAttribute("aria-hidden") !== "true");
    expect(exposed.map((el) => el.outerHTML.slice(0, 60))).toEqual([]);
  });

  test("named widgets carry their name, and every reference resolves", () => {
    for (const el of all('[role="img"], [role="group"], dialog, section, a[href]')) {
      const refs = el.getAttribute("aria-labelledby") ?? el.getAttribute("aria-labelledby") ?? "";
      for (const ref of refs.split(/\s+/).filter(Boolean)) expect(id(ref)).toBe(ref);
      if (el.hasAttribute("role") && !name(el)) expect(el.outerHTML.slice(0, 80)).toBe("");
    }
    expect(id("langs")).toBe("langs");
    expect(id("diskMeter")).toBe("diskMeter");
    expect(id("confirm")).toBe("confirm");
    expect(id("confirmTitle")).toBe("confirmTitle");
  });

  test("hidden elements are actually hidden by the stylesheet", () => {
    expect(css).toMatch(/\[hidden\]\s*\{[^}]*display:\s*none\s*!important/);
    expect(all("[hidden]").map((el) => el.getAttribute("id"))).toContain("result");
  });

  test("keyboard focus is always visible", () => {
    expect(css).toContain(":focus-visible");
    expect(css).toMatch(/:focus-visible\s*\{[^}]*outline:\s*2px solid/);
  });
});