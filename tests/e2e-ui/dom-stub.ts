import { readFile } from "node:fs/promises";
import { join } from "node:path";

const VOID_TAGS = new Set([
  "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
  "source", "track", "wbr", "circle", "ellipse", "line", "path", "polygon",
  "polyline", "rect", "stop", "use",
]);

const ENTITIES: Record<string, string> = {
  amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", "#39": "'", "#x27": "'",
};

export type StubEvent = { type: string; target: El; currentTarget: El };

export type StyleBag = { setProperty(name: string, value: string): void } & Record<string, unknown>;

export type Kid = El | string | null | undefined | false | ((...args: unknown[]) => unknown);

const kebab = (key: string): string => key.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`);
const camel = (key: string): string => key.replace(/-([a-z])/g, (_, c: string) => c.toUpperCase());
const decode = (text: string): string =>
  text.replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z]+);/g, (whole, body: string) => ENTITIES[body] ?? whole);

class ClassList {
  readonly #el: El;

  constructor(el: El) {
    this.#el = el;
  }

  #list(): string[] {
    return (this.#el.attrs.get("class") ?? "").split(/\s+/).filter(Boolean);
  }

  #write(items: string[]): void {
    this.#el.attrs.set("class", items.join(" "));
  }

  contains(token: string): boolean {
    return this.#list().includes(token);
  }

  add(...tokens: string[]): void {
    const items = this.#list();
    for (const token of tokens) if (!items.includes(token)) items.push(token);
    this.#write(items);
  }

  remove(...tokens: string[]): void {
    this.#write(this.#list().filter((token) => !tokens.includes(token)));
  }

  toggle(token: string, force?: boolean): boolean {
    const on = force ?? !this.contains(token);
    if (on) this.add(token);
    else this.remove(token);
    return on;
  }
}

type Attr = { name: string; value: string | null };
type Compound = { tag: string; classes: string[]; attrs: Attr[] };

const selectorCache = new Map<string, Compound[]>();

function compound(text: string): Compound {
  const parsed: Compound = { tag: "", classes: [], attrs: [] };
  for (const token of text.match(/^[a-zA-Z][\w-]*|\.[\w-]+|\[[^\]]+\]/g) ?? []) {
    if (token.startsWith(".")) {
      parsed.classes.push(token.slice(1));
    } else if (token.startsWith("[")) {
      const [name, value] = token.slice(1, -1).split("=");
      parsed.attrs.push({ name: name ?? "", value: value === undefined ? null : value.replace(/^["']|["']$/g, "") });
    } else {
      parsed.tag = token.toLowerCase();
    }
  }
  return parsed;
}

function parts(selector: string): Compound[] {
  const cached = selectorCache.get(selector);
  if (cached) return cached;
  const parsed = selector.trim().split(/\s+/).map(compound);
  selectorCache.set(selector, parsed);
  return parsed;
}

function matches(el: El, part: Compound): boolean {
  if (part.tag && el.tag !== part.tag) return false;
  if (!part.classes.every((name) => el.classList.contains(name))) return false;
  return part.attrs.every(({ name, value }) =>
    value === null ? el.attrs.has(name) : el.attrs.get(name) === value,
  );
}

function chain(el: El, list: Compound[]): boolean {
  const last = list[list.length - 1];
  if (!last || !matches(el, last)) return false;
  let node = el.parent;
  for (let i = list.length - 2; i >= 0; i--) {
    const part = list[i];
    if (!node || !part || !matches(node, part)) return false;
    node = node.parent;
  }
  return true;
}

function descendants(root: El): El[] {
  const out: El[] = [];
  const stack = [...root.children].reverse();
  while (stack.length) {
    const node = stack.pop();
    if (!node) break;
    out.push(node);
    for (const child of [...node.children].reverse()) stack.push(child);
  }
  return out;
}

export class El {
  readonly tag: string;
  readonly children: El[] = [];
  readonly attrs = new Map<string, string>();
  readonly props: Record<string, string> = {};
  readonly classList: ClassList;
  readonly style: StyleBag;
  readonly dataset: Record<string, string>;
  readonly #handlers = new Map<string, ((event: StubEvent) => void)[]>();
  parent: El | null = null;
  documentElement: El | null = null;
  activeElement: El | null = null;
  hidden = false;
  disabled = false;
  open = false;
  returnValue = "";
  lang = "";
  #text = "";

  constructor(tag: string) {
    this.tag = tag.toLowerCase();
    this.classList = new ClassList(this);
    this.style = { setProperty: (name: string, value: string) => void (this.props[name] = value) };
    this.dataset = new Proxy({} as Record<string, string>, {
      get: (_, key: string) => this.attrs.get(`data-${kebab(key)}`) ?? "",
      set: (_, key: string, value: unknown) => {
        this.attrs.set(`data-${kebab(key)}`, String(value));
        return true;
      },
      has: (_, key: string) => this.attrs.has(`data-${kebab(key)}`),
      ownKeys: () => [...this.attrs.keys()].filter((k) => k.startsWith("data-")).map((k) => camel(k.slice(5))),
      getOwnPropertyDescriptor: () => ({ enumerable: true, configurable: true }),
    });
  }

  get className(): string {
    return this.attrs.get("class") ?? "";
  }

  set className(value: string) {
    this.attrs.set("class", value);
  }

  get textContent(): string {
    return this.#text + this.children.map((child) => child.textContent).join("");
  }

  set textContent(value: string) {
    this.#text = String(value);
    this.children.length = 0;
  }

  get innerHTML(): string {
    const inner = this.#text + this.children.map((child) => child.outerHTML).join("");
    return `<${this.tag}>${inner}</${this.tag}>`;
  }

  set innerHTML(value: string) {
    this.children.length = 0;
    this.#text = String(value);
  }

  get outerHTML(): string {
    const inner = this.#text + this.children.map((child) => child.outerHTML).join("");
    const attrs = [...this.attrs].map(([key, value]) => ` ${key}="${value}"`).join("");
    return `<${this.tag}${attrs}>${inner}</${this.tag}>`;
  }

  setAttribute(name: string, value: string): void {
    this.attrs.set(name.toLowerCase(), String(value));
  }

  getAttribute(name: string): string | null {
    return this.attrs.get(name.toLowerCase()) ?? null;
  }

  hasAttribute(name: string): boolean {
    return this.attrs.has(name.toLowerCase());
  }

  append(...kids: Kid[]): void {
    for (const kid of kids.flat()) {
      if (typeof kid === "string") this.#text += kid;
      else if (kid instanceof El) {
        kid.parent = this;
        this.children.push(kid);
      }
    }
  }

  replaceChildren(...kids: Kid[]): void {
    this.children.length = 0;
    this.#text = "";
    this.append(...kids);
  }

  addEventListener(type: string, handler: (event: StubEvent) => void): void {
    const list = this.#handlers.get(type) ?? [];
    list.push(handler);
    this.#handlers.set(type, list);
  }

  dispatch(type: string, target: El = this): StubEvent {
    const event: StubEvent = { type, target, currentTarget: this };
    for (let node: El | null = this; node; node = node.parent) {
      for (const handler of [...(node.#handlers.get(type) ?? [])]) handler({ ...event, currentTarget: node });
    }
    return event;
  }

  getBoundingClientRect(): { width: number; height: number; top: number; left: number; right: number; bottom: number } {
    return { width: 0, height: 0, top: 0, left: 0, right: 0, bottom: 0 };
  }

  // Minimal focus model: focus() records the element on the document root so a
  // test can assert app.js restored focus after a re-render.
  focus(): void {
    let node: El = this;
    while (node.parent) node = node.parent;
    node.activeElement = this;
  }

  animate(): { finished: Promise<void> } {
    return { finished: Promise.resolve() };
  }

  showModal(): void {
    this.open = true;
  }

  close(value?: string): void {
    if (value !== undefined) this.returnValue = value;
    this.open = false;
    this.dispatch("close");
  }

  querySelectorAll(selector: string): El[] {
    const list = parts(selector);
    return descendants(this).filter((el) => chain(el, list));
  }

  querySelector(selector: string): El | null {
    return this.querySelectorAll(selector)[0] ?? null;
  }

  closest(selector: string): El | null {
    for (let node: El | null = this; node; node = node.parent) if (chain(node, parts(selector))) return node;
    return null;
  }

  createElement(tag: string): El {
    return new El(tag);
  }

  createElementNS(_ns: string, tag: string): El {
    return new El(tag);
  }

  getElementById(id: string): El | null {
    return descendants(this).find((el) => el.attrs.get("id") === id) ?? null;
  }
}

export function parseDocument(html: string): El {
  const doc = new El("#document");
  const stack: El[] = [doc];
  const tag = /<(\/?)([a-zA-Z][\w-]*)((?:"[^"]*"|'[^']*'|[^>"'])*?)(\/?)>/g;
  const text = (value: string): void => {
    const trimmed = value.replace(/\s+/g, " ");
    if (trimmed) stack[stack.length - 1]?.append(trimmed);
  };
  let at = 0;
  while (at < html.length) {
    tag.lastIndex = at;
    const match = tag.exec(html);
    if (!match) break;
    text(html.slice(at, match.index));
    const [, closing = "", name = "", raw = "", selfClose = ""] = match;
    const lower = name.toLowerCase();
    if (closing === "/") {
      for (let i = stack.length - 1; i > 0; i--) {
        if (stack[i]?.tag === lower) {
          stack.length = i;
          break;
        }
      }
    } else {
      const el = new El(lower);
      for (const attr of raw.matchAll(/([\w:-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/g)) {
        const value = attr[2] ?? attr[3] ?? attr[4] ?? "";
        if (attr[1]) el.attrs.set(attr[1].toLowerCase(), decode(value));
      }
      stack[stack.length - 1]?.append(el);
      if (selfClose !== "/" && !VOID_TAGS.has(lower)) stack.push(el);
    }
    at = tag.lastIndex;
  }
  text(html.slice(at));
  doc.documentElement = doc.children[0] ?? null;
  return doc;
}

export function accessibleName(doc: El, el: El): string {
  const label = el.getAttribute("aria-label");
  if (label !== null && label.trim()) return label;
  const refs = el.getAttribute("aria-labelledby");
  if (refs !== null) {
    const text = refs
      .split(/\s+/)
      .map((id) => doc.getElementById(id)?.textContent ?? "")
      .join(" ")
      .trim();
    if (text) return text;
  }
  const title = el.getAttribute("title");
  if (title !== null && title.trim()) return title;
  return el.textContent.trim();
}

export async function waitFor(ready: () => boolean, label: string, timeoutMs = 2000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!ready()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${label}`);
    await Bun.sleep(5);
  }
}

export async function readUiAsset(name: string): Promise<string> {
  return await readFile(join(import.meta.dir, "..", "..", "src", "ui", "public", name), "utf8");
}
