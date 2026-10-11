import { type El, accessibleName, parseDocument } from "./dom-stub.ts";

export type Reply = { status: number; body: unknown };
export type Responder = (path: string, init: { method: string; body: string }) => Reply;
export type Request = { path: string; method: string; body: unknown };

export type Stub = {
  document: El;
  missing: string[];
  requests: Request[];
  respond: (responder: Responder) => void;
  click: (el: El) => void;
  byId: (id: string) => El;
  all: (selector: string) => El[];
  text: (el: El | null | undefined) => string;
  accessibleName: (el: El) => string;
  restore: () => void;
};

export function installDom(html: string, responder: Responder): Stub {
  const doc = parseDocument(html);
  const missing: string[] = [];
  const requests: Request[] = [];
  const findById = doc.getElementById.bind(doc);
  let active = responder;

  doc.getElementById = (id: string): El | null => {
    const hit = findById(id);
    if (!hit) missing.push(id);
    return hit;
  };

  const globals = globalThis as Record<string, unknown>;
  const store = new Map<string, string>();
  const saved = new Map<string, { present: boolean; value: unknown }>();
  const set = (key: string, value: unknown): void => {
    if (!saved.has(key)) saved.set(key, { present: key in globals, value: globals[key] });
    globals[key] = value;
  };
  const restore = (): void => {
    for (const [key, original] of saved) {
      if (original.present) globals[key] = original.value;
      else delete globals[key];
    }
    saved.clear();
  };
  let frames = 0;
  let base = -1;

  set("document", doc);
  set("matchMedia", (query: string) => ({ media: query, matches: false }));
  set("localStorage", {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => void store.set(key, value),
    removeItem: (key: string) => void store.delete(key),
  });
  set("requestAnimationFrame", (callback: (stamp: number) => void) => {
    if (base < 0) base = performance.now() - 16;
    callback(base + 16 * ++frames);
    return 0;
  });
  set("cancelAnimationFrame", () => undefined);
  set("fetch", async (path: string, init?: { method?: string; body?: string }) => {
    const method = init?.method ?? "GET";
    const body = init?.body ?? "";
    let parsed: unknown = body;
    if (body) {
      try {
        parsed = JSON.parse(body);
      } catch {
        parsed = null;
      }
    }
    requests.push({ path: String(path), method, body: parsed });
    const reply = active(String(path), { method, body });
    return { ok: reply.status >= 200 && reply.status < 300, status: reply.status, json: async () => reply.body };
  });

  const byId = (id: string): El => {
    const el = doc.getElementById(id);
    if (!el) throw new Error(`stub: no element with id "${id}"`);
    return el;
  };

  return {
    document: doc,
    missing,
    requests,
    respond: (next) => void (active = next),
    click: (el) => void el.dispatch("click", el),
    byId,
    all: (selector) => doc.querySelectorAll(selector),
    text: (el) => el?.textContent ?? "",
    accessibleName: (el) => accessibleName(doc, el),
    restore,
  };
}
