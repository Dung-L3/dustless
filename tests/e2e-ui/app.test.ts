import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { join } from "node:path";
import { STRINGS } from "../../src/ui/public/i18n.js";
import { type El, readUiAsset, waitFor } from "./dom-stub.ts";
import { installDom } from "./dom-globals.ts";
import {
  BLOCKED_GRADLE,
  BLOCKED_RULE,
  BUILD_ONE,
  BUILD_THREE,
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
const APP_JS = join(import.meta.dir, "..", "..", "src", "ui", "public", "app.js");

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

const rows = (): El[] => stub.byId("groups").querySelectorAll(".row");
const groups = (): El[] => stub.byId("groups").querySelectorAll(".group");
const rowFor = (ruleId: string, path: string): El | undefined =>
  rows().find((row) => row.dataset.decision === `${ruleId} :: ${path}`);
const switched = (row: El, choice: string): El | undefined =>
  row.querySelectorAll(".switch button").find((button) => button.dataset.choice === choice);
const choiceOf = (row: El): { delete: string; keep: string } => {
  const buttons = row.querySelectorAll(".switch button");
  const press = (name: string): string =>
    buttons.find((button) => button.dataset.choice === name)?.getAttribute("aria-pressed") ?? "";
  return { delete: press("delete"), keep: press("keep") };
};
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
    const byRule = MIXED_REPORT.findings.reduce<Record<string, number>>((acc, finding) => {
      acc[finding.ruleId] = (acc[finding.ruleId] ?? 0) + finding.bytes;
      return acc;
    }, {});
    const order = Object.entries(byRule).sort((a, b) => (b[1] ?? 0) - (a[1] ?? 0)).map(([ruleId]) => ruleId);
    expect(groups().map((group) => group.querySelector(".group__id")?.textContent?.split(" ")[0])).toEqual(order);
    expect(stub.byId("groups").children.length).toBe(3);
  });

  test("every row carries its finding key, tier and chosen state", () => {
    expect(rows().length).toBe(MIXED_REPORT.findings.length);
    for (const row of rows()) {
      expect(row.dataset.decision).toMatch(/^[\w.]+ :: \//);
      expect(["green", "yellow", "red"]).toContain(row.dataset.tier ?? "");
      expect(["true", "false"]).toContain(row.dataset.chosen ?? "");
    }
  });

  test("the empty state replaces the groups and disables the CTA", async () => {
    report = EMPTY_REPORT;
    stub.click(stub.byId("scanBtn"));
    await waitFor(() => !stub.byId("emptyState").hidden, "the empty state");
    expect(stub.byId("groups").children.length).toBe(0);
    expect(stub.byId("cleanBtn").disabled).toBe(true);
    expect(stub.byId("cleanHint").textContent).toBe(t("cleanHintNone"));
  });

  test("a failing scan renders the error state with the server message", async () => {
    mode = "error";
    stub.click(stub.byId("scanBtn"));
    await waitFor(() => !stub.byId("errorState").hidden, "the error state");
    expect(stub.byId("errorBody").textContent).toBe("scan exploded");
    expect(stub.byId("groups").hidden).toBe(true);
    stub.click(stub.byId("retryBtn"));
    await waitFor(() => !stub.byId("scanState").hidden, "the retry scan");
  });
});

describe("blocked findings are never sold as deletable", () => {
  const blockedRow = () => rowFor(BLOCKED_RULE, BLOCKED_GRADLE);

  test("the blocked row carries the localised blocked label, not colour alone", () => {
    const row = blockedRow();
    expect(row?.textContent ?? "").toContain(t("blocked"));
  });

  test("the blocked row is rendered as blocked, not as a yellow item", () => {
    expect(blockedRow()?.dataset.tier).not.toBe("yellow");
  });

  test("the blocked row never gets a delete control", () => {
    const button = switched(blockedRow() as El, "delete");
    expect({ hasDelete: !!button, pressed: button?.getAttribute("aria-pressed") ?? null }).toEqual({
      hasDelete: false,
      pressed: null,
    });
  });

  test("the blocked row is left out of the delete selection", () => {
    expect(blockedRow()?.dataset.chosen).toBe("false");
  });

  test("the reclaimable figure equals what the server says is reclaimable", () => {
    expect(heroBytes()).toBe(MIXED_REPORT.reclaimable);
  });

  test("the blocked tier card counts the blocked findings", () => {
    expect(stub.byId("redCount").textContent).toBe(String(MIXED_REPORT.totals.blocked.count));
  });
});

describe("a red-tier finding is inert", () => {
  test("a red row shows the blocked hint and offers no control", async () => {
    report = RED_REPORT;
    stub.click(stub.byId("scanBtn"));
    await waitFor(scanFinished, "the red-only scan");
    const row = rowFor("docs.archive", RED_HOME);
    expect(row?.textContent).toContain(t("blocked"));
    expect(row?.querySelectorAll(".switch button").length ?? 0).toBe(0);
    expect(row?.dataset.chosen).toBe("false");
  });
});

describe("decision controls", () => {
  test("the reclaimable figure renders a real number, never NaN, undefined or null", () => {
    const value = stub.byId("reclaimValue").textContent;
    expect(value).not.toMatch(/NaN|undefined|null/);
    expect(Number.isFinite(Number(value.replace(/[^0-9.]/g, "")))).toBe(true);
  });

  test("the yellow decision control announces that it applies to the whole rule", () => {
    expect(stub.byId("groups").querySelector(".switch")?.getAttribute("aria-label")).toBe(t("ruleWide"));
  });

  test("keeping one yellow item mirrors onto every sibling of the same rule", () => {
    const first = rowFor(YELLOW_RULE, BUILD_ONE) as El;
    stub.click(switched(first, "keep") as El);
    for (const path of [BUILD_ONE, BUILD_TWO, BUILD_THREE]) {
      const kept = { path, ...choiceOf(rowFor(YELLOW_RULE, path) as El) };
      expect(kept).toEqual({ path, delete: "false", keep: "true" });
      expect(rowFor(YELLOW_RULE, path)?.dataset.chosen).toBe("false");
    }
    expect((rowFor(YELLOW_RULE, BUILD_ONE) as El).textContent).toContain(t("kept"));
    expect((rowFor(GREEN_RULE, NPM_CACHE) as El).dataset.chosen).toBe("true");
  });

  test("the hero and the CTA hint follow the rule-wide decision", () => {
    const first = rowFor(YELLOW_RULE, BUILD_ONE) as El;
    stub.click(switched(first, "keep") as El);
    const kept = heroBytes();
    const hint = stub.byId("cleanHint").textContent;
    stub.click(switched(first, "delete") as El);
    const restored = heroBytes();
    expect({ shrunk: kept < restored, hintChanged: hint !== stub.byId("cleanHint").textContent }).toEqual({
      shrunk: true,
      hintChanged: true,
    });
    expect(rowFor(YELLOW_RULE, BUILD_ONE)?.dataset.chosen).toBe("true");
  });

  test("the confirm dialog lists exactly the selected findings and their total", () => {
    stub.click(stub.byId("cleanBtn"));
    const listed = stub.byId("confirmList").children.map((li) => li.textContent);
    expect(stub.byId("confirm").open).toBe(true);
    expect(listed.length).toBe(MIXED_REPORT.findings.length);
    for (const finding of MIXED_REPORT.findings) {
      expect(listed.some((text) => text.includes(finding.path))).toBe(true);
    }
    expect(stub.byId("confirmTotal").textContent).toBe(t("confirmTotal", { amount: "26 MB" }));
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