import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { STRINGS } from "../../src/ui/public/i18n.js";
import { type El, readUiAsset, waitFor } from "./dom-stub.ts";
import { installDom } from "./dom-globals.ts";
import {
  BLOCKED_GRADLE,
  BLOCKED_RULE,
  BUILD_ONE,
  BUILD_TWO,
  EMPTY_REPORT,
  GREEN_RULE,
  MIXED_REPORT,
  NPM_CACHE,
  RED_HOME,
  RED_REPORT,
  RULES,
  SPACE,
  YELLOW_RULE,
} from "./fixture.ts";

const EN = STRINGS["en"] as Record<string, string>;
const t = (key: string, vars?: Record<string, unknown>) => {
  let text = EN[key] ?? key;
  for (const [name, value] of Object.entries(vars ?? {})) text = text.replaceAll(`{${name}}`, String(value));
  return text;
};

const HTML = await readUiAsset("index.html");
const APP_JS = import.meta.dir + "/../../src/ui/public/app.js";

const APPLY_OK = {
  outcomes: MIXED_REPORT.findings.map((finding) => ({
    ruleId: finding.ruleId,
    tier: finding.tier,
    path: finding.path,
    status: "skipped",
    bytes: finding.bytes,
    detail: "",
  })),
  freed: 0,
  freeBefore: SPACE.free,
  freeAfter: SPACE.free,
  elapsedMs: 12,
};

let mode: "mixed" | "empty" | "red" | "error" = "mixed";
let report = MIXED_REPORT;

const stub = installDom(HTML, (path) => {
  if (path === "/api/scan") {
    if (mode === "error") return { status: 500, body: { error: "scan exploded" } };
    return { status: 200, body: report };
  }
  if (path === "/api/rules") return { status: 200, body: RULES };
  if (path === "/api/space") return { status: 200, body: SPACE };
  if (path === "/api/apply") return { status: 200, body: APPLY_OK };
  return { status: 404, body: { error: `no route for ${path}` } };
});

await import(APP_JS);
await waitFor(() => stub.byId("scanState").hidden, "the boot scan to settle");

afterAll(() => stub.restore());

const groupContainer = (tab: string): El => stub.byId(`tab${tab[0]!.toUpperCase() + tab.slice(1)}`).querySelector('[data-tab-group]') as unknown as El;
const allGroups = (): El[] => ["safe", "review", "locked"].flatMap((tab) => groupContainer(tab).children);
const rows = (): El[] => allGroups().flatMap((g) => g.querySelectorAll(".row"));
const rowFor = (ruleId: string, path: string): El | undefined =>
  rows().find((row) => row.dataset.decision === `${ruleId} :: ${path}`);
const checkboxFor = (row: El): El | undefined => row.querySelector('input[type="checkbox"]') ?? undefined;
const heroBytes = (): number => {
  const value = Number(stub.byId("reclaimValue").textContent.replace(/[^0-9.]/g, ""));
  const unit = stub.byId("reclaimUnit").textContent.trim();
  const scale = unit === "GB" ? 1024 ** 3 : unit === "MB" ? 1024 ** 2 : unit === "KB" ? 1024 : 1;
  return value * scale;
};
const scanFinished = () => stub.byId("scanState").hidden;

beforeEach(async () => {
  mode = "mixed";
  report = MIXED_REPORT;
  stub.click(stub.byId('langs').querySelector('[data-lang="en"]') as El);
  stub.click(stub.byId("scanBtn"));
  await waitFor(scanFinished, "the stubbed scan to settle");
});

describe("app boot", () => {
  test("every element app.js looks up by id exists in index.html", () => {
    expect(stub.missing).toEqual([]);
  });

  test("one collapsible group is rendered per rule id", () => {
    expect(allGroups().length).toBe(3);
  });

  test("every row carries its finding key, tier and chosen state", () => {
    expect(rows().length).toBe(MIXED_REPORT.findings.length);
    for (const row of rows()) {
      expect(row.dataset.decision).toMatch(/^[\w.]+ :: \//);
      expect(["green", "yellow", "blocked"]).toContain(row.dataset.tier ?? "");
      expect(["true", "false"]).toContain(row.dataset.chosen ?? "");
    }
  });

  test("the empty state replaces the groups and disables the CTA", async () => {
    report = EMPTY_REPORT;
    stub.click(stub.byId("scanBtn"));
    await waitFor(() => !stub.byId("emptyState").hidden, "the empty state");
    expect(allGroups().every((g) => g.children.length === 0)).toBe(true);
    expect(stub.byId("cleanBtn").disabled).toBe(true);
    expect(stub.byId("cleanHint").textContent).toBe(t("selectedNone"));
  });

  test("a failing scan renders the error state with the server message", async () => {
    mode = "error";
    stub.click(stub.byId("scanBtn"));
    await waitFor(() => !stub.byId("errorState").hidden, "the error state");
    expect(stub.byId("errorBody").textContent).toBe("scan exploded");
    stub.click(stub.byId("retryBtn"));
    await waitFor(() => !stub.byId("scanState").hidden, "the retry scan");
  });
});

describe("blocked findings are never sold as deletable", () => {
  const blockedRow = () => rowFor(BLOCKED_RULE, BLOCKED_GRADLE);

  test("the blocked row carries the localised blocked label, not colour alone", () => {
    expect(blockedRow()?.textContent ?? "").toContain(t("blocked"));
  });

  test("the blocked row is rendered as blocked, not as a yellow item", () => {
    expect(blockedRow()?.dataset.tier).toBe("blocked");
  });

  test("the blocked row never gets a delete control", () => {
    const input = checkboxFor(blockedRow() as El);
    expect(input).toBeUndefined();
  });

  test("the blocked row is left out of the delete selection", () => {
    expect(blockedRow()?.dataset.chosen).toBe("false");
  });

  test("the blocked row sits in the locked tab only", () => {
    const inSafe = groupContainer("safe").querySelectorAll(".row").some((row) => row.dataset.decision?.includes(BLOCKED_GRADLE));
    const inReview = groupContainer("review").querySelectorAll(".row").some((row) => row.dataset.decision?.includes(BLOCKED_GRADLE));
    const inLocked = groupContainer("locked").querySelectorAll(".row").some((row) => row.dataset.decision?.includes(BLOCKED_GRADLE));
    expect({ safe: inSafe, review: inReview, locked: inLocked }).toEqual({ safe: false, review: false, locked: true });
  });

  test("the safe tab total equals the green total only", () => {
    expect(stub.byId("greenSize").textContent).toBe("7 MB");
  });

  test("the blocked tier card counts the blocked findings", () => {
    expect(stub.byId("blockedCount").textContent).toBe(String(MIXED_REPORT.totals.blocked.count));
  });
});

describe("a red-tier finding is inert", () => {
  test("a red row shows the blocked hint and offers no control", async () => {
    report = RED_REPORT;
    stub.click(stub.byId("scanBtn"));
    await waitFor(scanFinished, "the red-only scan");
    const row = rowFor("docs.archive", RED_HOME);
    expect(row?.textContent).toContain(t("blockedNotice"));
    expect(row?.querySelectorAll("input[type=checkbox]").length ?? 0).toBe(0);
    expect(row?.dataset.tier).toBe("blocked");
  });
});

describe("decision controls", () => {
  test("the reclaimable figure renders a real number, never NaN, undefined or null", () => {
    const value = stub.byId("reclaimValue").textContent;
    expect(value).not.toMatch(/NaN|undefined|null/);
    expect(Number.isFinite(Number(value.replace(/[^0-9.]/g, "")))).toBe(true);
  });

  test("the yellow decision control is a per-item checkbox", () => {
    const row = rowFor(YELLOW_RULE, BUILD_ONE) as El;
    const input = checkboxFor(row);
    expect(input?.getAttribute("type")).toBe("checkbox");
    expect(input?.closest("label")?.getAttribute("aria-label")).toBe(t("ruleWide"));
  });

  test("toggling one yellow item does not affect siblings", () => {
    let first = rowFor(YELLOW_RULE, BUILD_ONE) as El;
    expect(first.dataset.chosen).toBe("false");
    stub.click(checkboxFor(first) as El);
    first = rowFor(YELLOW_RULE, BUILD_ONE) as El;
    const sibling = rowFor(YELLOW_RULE, BUILD_TWO) as El;
    expect(first.dataset.chosen).toBe("true");
    expect(sibling.dataset.chosen).toBe("false");
  });

  test("the hero and the CTA hint follow the per-item selection", () => {
    let first = rowFor(YELLOW_RULE, BUILD_ONE) as El;
    expect(heroBytes()).toBe(0);
    stub.click(checkboxFor(first) as El);
    expect(heroBytes()).toBe(8 * 1024 * 1024);
    expect(stub.byId("cleanHint").textContent).toContain("1");
  });

  test("the confirm dialog lists every deletable item and starts with nothing selected", () => {
    stub.click(stub.byId("cleanBtn"));
    const deletable = MIXED_REPORT.findings.filter((f) => !f.blocked);
    const listed = stub.byId("confirmList").children.map((li) => li.textContent);
    expect(stub.byId("confirm").open).toBe(true);
    expect(listed.length).toBe(deletable.length);
    for (const finding of MIXED_REPORT.findings.filter((f) => f.blocked)) {
      expect(listed.join(" ")).not.toContain(finding.path);
    }
    for (const finding of deletable) {
      expect(listed.some((text) => text.includes(finding.path))).toBe(true);
    }
    expect(stub.byId("confirmTotal").textContent).toBe(t("confirmTotal", { amount: "0 B" }));
    expect(stub.byId("confirmGo").disabled).toBe(true);
    const sheetRowFor = (path: string) => stub.byId("confirmList").children.find((li) => li.textContent.includes(path));
    let firstGreen = sheetRowFor(NPM_CACHE) as El;
    stub.click(checkboxFor(firstGreen) as El);
    expect(stub.byId("confirmTotal").textContent).toBe(t("confirmTotal", { amount: "5 MB" }));
    expect(stub.byId("confirmGo").disabled).toBe(false);
    let firstYellow = sheetRowFor(BUILD_ONE) as El;
    stub.click(checkboxFor(firstYellow) as El);
    expect(stub.byId("confirmTotal").textContent).toBe(t("confirmTotal", { amount: "13 MB" }));
  });
});

describe("the apply payload", () => {
  const postApply = async (): Promise<Record<string, string>> => {
    stub.click(stub.byId("cleanBtn"));
    const dialog = stub.byId("confirm");
    dialog.returnValue = "confirm";
    dialog.close();
    await waitFor(() => !stub.byId("result").hidden, "the apply result");
    const call = stub.requests.filter((request) => request.path === "/api/apply").at(-1);
    return ((call?.body as { tiers?: Record<string, string> } | undefined)?.tiers ?? {}) as Record<string, string>;
  };

  test("every rule in the report is answered with a tier the API accepts", async () => {
    const tiers = await postApply();
    expect(Object.keys(tiers).sort()).toEqual([BLOCKED_RULE, GREEN_RULE, YELLOW_RULE].sort());
    for (const value of Object.values(tiers)) expect(["green", "yellow", "skip"]).toContain(value);
  });

  test("a rule holding a blocked finding is never asked to delete", async () => {
    expect({ ruleId: BLOCKED_RULE, requested: (await postApply())[BLOCKED_RULE] }).toEqual({
      ruleId: BLOCKED_RULE,
      requested: "skip",
    });
  });

  test("the result panel reports measured numbers, never placeholders", async () => {
    await postApply();
    for (const id of ["outDeleted", "outSkipped", "outFailed", "outFree", "freedValue", "freedUnit"]) {
      expect({ id, text: stub.byId(id).textContent }).toMatchObject({ id });
      expect(stub.byId(id).textContent).not.toMatch(/NaN|undefined|null/);
    }
    expect(stub.byId("outSkipped").textContent).toBe("6");
    expect(stub.byId("outDeleted").textContent).toBe("0");
  });
});

describe("theme toggle", () => {
  test("clicking the theme button cycles themes, updates the root, and persists", () => {
    const doc = stub.document.documentElement as El;
    const ls = (globalThis as { localStorage?: Storage }).localStorage;
    expect(ls?.getItem("dustless.theme")).toBe("system");
    stub.click(stub.byId("themeBtn"));
    const stored = ls?.getItem("dustless.theme") ?? "";
    expect(["light", "dark", "system"]).toContain(stored);
    if (stored === "light") expect(doc.dataset.theme).toBe("light");
    else expect(doc.dataset.theme).not.toBe("light");
  });
});

describe("locked findings render their note and full path", () => {
  test("the blocked row displays its note prominently", () => {
    const row = rowFor(BLOCKED_RULE, BLOCKED_GRADLE) as El;
    expect(row.textContent).toContain("KHÔNG XÓA:");
  });

  test("a row path is the full path, never truncated", () => {
    const row = rowFor(GREEN_RULE, NPM_CACHE) as El;
    const pathNode = row.querySelector(".row__path") as El;
    expect(pathNode.textContent).toBe(NPM_CACHE);
  });
});

describe("language switching", () => {
  test("the language buttons repaint every data-i18n node", () => {
    const before = stub.all("[data-i18n]").map((node) => node.textContent);
    stub.click(stub.byId('langs').querySelector('[data-lang="vi"]') as El);
    const after = stub.all("[data-i18n]").map((node) => node.textContent);
    expect(after).toEqual(expect.arrayContaining([STRINGS["vi"]?.["cleanNow"], STRINGS["vi"]?.["rescan"]]));
    expect(before).not.toEqual(after);
    expect(after.every((text) => /[A-Za-zÀ-ỹ一-鿿]/.test(text ?? ""))).toBe(true);
    expect(stub.document.documentElement?.lang).toBe("vi");
  });

  test("aria-pressed tracks the active language and the choice is persisted", () => {
    stub.click(stub.byId('langs').querySelector('[data-lang="zh"]') as El);
    const pressed = stub.all("[data-lang]").map((node) => `${node.dataset.lang}:${node.getAttribute("aria-pressed")}`);
    expect(pressed).toEqual(["vi:false", "en:false", "zh:true"]);
    expect((globalThis as { localStorage?: Storage }).localStorage?.getItem("dustless.lang")).toBe("zh");
  });
});
