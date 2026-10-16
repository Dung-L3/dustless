import { createTranslator } from "./i18n.js";
import { h, glyph, number, size, heroSize, clockLabel, countUp, findingKey } from "./ui-helpers.js";

const LANG_KEY = "dustless.lang";
const THEME_KEY = "dustless.theme";
const REDUCED = matchMedia("(prefers-reduced-motion: reduce)");
const TABS = ["safe", "review", "locked"];
const TIERS = { safe: "green", review: "yellow", locked: "blocked" };
const $ = (id) => document.getElementById(id);

const dom = {
  themeBtn: $("themeBtn"), scanBtn: $("scanBtn"), cleanBtn: $("cleanBtn"),
  langs: $("langs"), freeStat: $("freeStat"), selectStat: $("selectStat"),
  reclaimValue: $("reclaimValue"), reclaimUnit: $("reclaimUnit"),
  freeValue: $("freeValue"), usedPercent: $("usedPercent"),
  diskMeter: $("diskMeter"), diskFill: $("diskFill"), cleanHint: $("cleanHint"),
  scanState: $("scanState"), scanTitle: $("scanTitle"), scanBody: $("scanBody"), scanClock: $("scanClock"),
  emptyState: $("emptyState"), emptyTitle: $("emptyTitle"), emptyBody: $("emptyBody"),
  errorState: $("errorState"), errorTitle: $("errorTitle"), errorBody: $("errorBody"),
  retryBtn: $("retryBtn"), result: $("result"), resultTitle: $("resultTitle"), resultBody: $("resultBody"),
  freedValue: $("freedValue"), freedUnit: $("freedUnit"),
  outDeleted: $("outDeleted"), outSkipped: $("outSkipped"), outFailed: $("outFailed"), outFree: $("outFree"),
  confirm: $("confirm"), confirmList: $("confirmList"), confirmTotal: $("confirmTotal"),
  confirmSelectedCount: $("confirmSelectedCount"), confirmLockedCount: $("confirmLockedCount"),
  confirmGo: $("confirmGo"), confirmCancel: $("confirmCancel"),
  toast: $("toast"), platformValue: $("platformValue"),
  tabSafeBtn: $("tabSafeBtn"), tabReviewBtn: $("tabReviewBtn"), tabLockedBtn: $("tabLockedBtn"),
  tabSafe: $("tabSafe"), tabReview: $("tabReview"), tabLocked: $("tabLocked"),
  safeMeta: $("safeMeta"), reviewMeta: $("reviewMeta"), lockedMeta: $("lockedMeta"),
  safeEmpty: $("safeEmpty"), reviewEmpty: $("reviewEmpty"), lockedEmpty: $("lockedEmpty"),
  safeGroup: $("tabSafe")?.querySelector('[data-tab-group="safe"]'),
  reviewGroup: $("tabReview")?.querySelector('[data-tab-group="review"]'),
  lockedGroup: $("tabLocked")?.querySelector('[data-tab-group="locked"]'),
  tiers: $("tiers"), tablist: $("tablist"),
};

const state = {
  lang: readLang(),
  theme: readTheme(),
  status: "scanning",
  report: null,
  rules: [],
  space: { free: 0, total: 0 },
  selected: new Set(),
  openGroups: new Map(),
  activeTab: "safe",
  message: "",
  shownBytes: -1,
};

let t = createTranslator(state.lang);
let clock = 0;
let toastTimer = 0;

function readLang() {
  const stored = localStorage.getItem(LANG_KEY);
  return ["vi", "en", "zh"].includes(stored) ? stored : "en";
}

function readTheme() {
  const stored = localStorage.getItem(THEME_KEY);
  return ["light", "dark", "system"].includes(stored) ? stored : "system";
}

async function api(path, options) {
  const response = await fetch(path, options);
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error ?? t("httpError", { status: response.status }));
  return payload;
}


// One predicate for "the engine will never delete this", used by every list,
// every control and the payload: a finding is inert when it is hard-blocked or
// on the red list, and those are exactly the findings that get no checkbox.
const isLocked = (finding) => finding.blocked || finding.tier === "red";

function tabFindings(tab) {
  if (!state.report) return [];
  if (tab === "locked") return state.report.findings.filter(isLocked);
  const tier = TIERS[tab];
  return state.report.findings.filter((f) => !isLocked(f) && f.tier === tier);
}

function groupByRule(findings) {
  const buckets = new Map();
  for (const finding of findings) {
    if (!buckets.has(finding.ruleId)) buckets.set(finding.ruleId, []);
    buckets.get(finding.ruleId).push(finding);
  }
  return [...buckets.entries()].map(([ruleId, items]) => {
    const sorted = items.sort((a, b) => b.bytes - a.bytes);
    return { ruleId, desc: sorted[0].desc, tier: sorted[0].tier, items: sorted, widest: sorted[0].bytes, total: sorted.reduce((s, f) => s + f.bytes, 0) };
  }).sort((a, b) => b.total - a.total);
}

function selectedBytes() {
  let bytes = 0;
  for (const key of state.selected) {
    const finding = byKey.get(key);
    if (finding) bytes += finding.bytes;
  }
  return bytes;
}

function selectedCount() {
  return state.selected.size;
}

function buildTierChoice() {
  const choices = {};
  if (!state.report) return choices;
  const ruleIds = new Set(state.report.findings.map((f) => f.ruleId));
  for (const ruleId of ruleIds) {
    const items = state.report.findings.filter((f) => f.ruleId === ruleId);
    const deletable = items.some((f) => !isLocked(f));
    const selected = items.some((f) => state.selected.has(findingKey(f)));
    if (!deletable || !selected) choices[ruleId] = "skip";
    else {
      const rule = state.rules.find((r) => r.id === ruleId);
      choices[ruleId] = rule?.tier === "green" ? "green" : "yellow";
    }
  }
  return choices;
}

const byKey = new Map();

function announce(text) {
  dom.toast.textContent = text;
  dom.toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (dom.toast.hidden = true), 4200);
}

function paintText() {
  document.documentElement.lang = state.lang;
  dom.langs.setAttribute("aria-label", t("language"));
  dom.themeBtn.setAttribute("aria-label", t("theme"));
  dom.themeBtn.setAttribute("title", t("theme"));
  dom.tiers.setAttribute("aria-label", t("riskTabs"));
  dom.tablist.setAttribute("aria-label", t("risk"));
  for (const button of dom.langs.querySelectorAll("[data-lang]")) {
    button.setAttribute("aria-pressed", String(button.dataset.lang === state.lang));
  }
  for (const node of document.querySelectorAll("[data-i18n]")) node.textContent = t(node.dataset.i18n);
}

function paintTheme() {
  const system = matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
  const resolved = state.theme === "system" ? system : state.theme;
  if (resolved === "light") document.documentElement.dataset.theme = "light";
  else delete document.documentElement.dataset.theme;
  localStorage.setItem(THEME_KEY, state.theme);
}

function paintMeter() {
  const { free, total } = state.space;
  if (!total) return;
  const used = Math.min(1, (total - free) / total);
  const percent = `${number(state.lang, used * 100, 0)}%`;
  dom.diskFill.style.setProperty("--used", String(used));
  dom.freeValue.textContent = size(state.lang, free);
  dom.usedPercent.textContent = percent;
  // The bar's width encodes *used* space, so the name must say used too.
  dom.diskMeter.setAttribute("aria-label", `${t("freeMeter")}: ${percent}`);
}

function paintSummary() {
  const pending = state.status === "scanning" || state.status === "working";
  const totals = state.report?.totals ?? {};
  const selectedSize = selectedBytes();
  if (selectedSize !== state.shownBytes) {
    state.shownBytes = selectedSize;
    const hero = heroSize(selectedSize);
    countUp(dom.reclaimValue, hero.value, (value) => number(state.lang, value, hero.digits));
    dom.reclaimUnit.textContent = hero.unit;
  }
  const safeBytes = totals.green?.bytes ?? 0;
  $("greenCount").textContent = number(state.lang, totals.green?.count ?? 0, 0);
  $("greenSize").textContent = size(state.lang, safeBytes);
  $("yellowCount").textContent = number(state.lang, totals.yellow?.count ?? 0, 0);
  $("yellowSize").textContent = size(state.lang, totals.yellow?.bytes ?? 0);
  $("blockedCount").textContent = number(state.lang, totals.blocked?.count ?? 0, 0);
  $("blockedSize").textContent = size(state.lang, totals.blocked?.bytes ?? 0);
  dom.freeStat.textContent = t("freeStat", { amount: size(state.lang, state.space.free) });
  dom.selectStat.textContent = t("selectedOf", { selected: selectedCount(), found: state.report?.findings.length ?? 0 });
  dom.cleanBtn.disabled = pending || state.selected.size === 0;
  dom.cleanHint.textContent = pending ? t("scanningHint") : state.selected.size === 0 ? t("selectedNone") : `${selectedCount()} · ${size(state.lang, selectedBytes())}`;
  dom.scanBtn.dataset.busy = String(pending);
}

function paintStates() {
  const busy = state.status === "scanning" || state.status === "working";
  dom.scanState.hidden = !busy;
  dom.emptyState.hidden = state.status !== "empty";
  dom.errorState.hidden = state.status !== "error";
  dom.result.hidden = state.status !== "done";
  dom.scanTitle.textContent = t(state.status === "working" ? "working" : "scanning");
  dom.scanBody.textContent = t(state.status === "working" ? "workingHint" : "scanningHint");
  dom.emptyTitle.textContent = t("emptyTitle");
  dom.emptyBody.textContent = t("emptyBody");
  dom.errorTitle.textContent = t("errorTitle");
  dom.errorBody.textContent = t("errorBody", { message: state.message });
  dom.resultTitle.textContent = t("resultTitle");
  dom.resultBody.textContent = t("resultBody");
}

function startClock() {
  const started = performance.now();
  clearInterval(clock);
  clock = setInterval(() => {
    dom.scanClock.textContent = t("elapsed", { s: clockLabel(state.lang, performance.now() - started) });
  }, 120);
  dom.scanClock.textContent = t("elapsed", { s: clockLabel(state.lang, 0) });
}

function provenance(finding) {
  const rule = state.rules.find((r) => r.id === finding.ruleId);
  const min = rule?.minAgeDays ?? "—";
  return t("provenance", { rule: finding.desc, age: Math.round(finding.ageDays), min, verified: t(finding.verified ? "verified" : "unverified") });
}

function renderRow(finding, index, group, tab, stagger) {
  const key = findingKey(finding);
  const chosen = state.selected.has(key);
  const locked = isLocked(finding);
  const note = finding.blocked ? finding.note : t("blockedNotice");
  return h("div", {
    class: "row",
    data: { tier: locked ? "blocked" : finding.tier, decision: key, chosen: String(chosen) },
    style: { "--i": String(stagger ? Math.min(index, 12) : 0) },
  },
    h("div", { class: "row__main" },
      h("p", { class: "row__path", title: finding.path }, h("bdi", { text: finding.path })),
      h("div", { class: "row__meta" },
        h("span", { class: "row__tag" }, glyph(locked ? "blocked" : finding.tier), t(locked ? "blocked" : finding.tier)),
        h("span", { text: t(finding.verified ? "verified" : "unverified") }),
        h("span", { text: t("ageDays", { n: Math.round(finding.ageDays) }) }),
        locked ? h("span", { text: t("lockedReason", { reason: note }) }) : null),
      locked ? h("p", { class: "row__note", text: note }) : null),
    h("div", { class: "row__right" },
      h("span", { class: "row__bytes", text: size(state.lang, finding.bytes) }),
      h("div", { class: "bar", style: { "--w": String(group.widest ? finding.bytes / group.widest : 0) } },
        h("span", { class: "bar__fill" }))),
    tab !== "locked" ? renderDecision(finding) : null);
}

function renderDecision(finding) {
  const key = findingKey(finding);
  const on = state.selected.has(key);
  return h("div", { class: "decision" },
    h("label", { class: "switch", role: "group", "aria-label": t("ruleWide") },
      h("input", {
        type: "checkbox", checked: on, "data-key": key,
        "aria-label": t("decisionA11y", { path: finding.path }),
        onclick: () => toggleFinding(key),
      }),
      h("span", { text: t(on ? "willDelete" : "kept") })));
}

function renderGroup(group, index, tab, stagger) {
  const open = state.openGroups.get(group.ruleId) ?? true;
  return h("div", {
    class: "group",
    data: { tier: group.items[0]?.blocked ? "blocked" : group.tier, open: String(open) },
    style: { "--i": String(stagger ? Math.min(index, 10) : 0) },
  },
    h("button", {
      type: "button", class: "group__head", "aria-expanded": String(open),
      "aria-label": `${t(open ? "collapseGroup" : "expandGroup")}: ${group.desc}`,
      "data-rule": group.ruleId,
      onclick: () => toggleGroup(group.ruleId),
    },
      glyph(group.items[0]?.blocked ? "blocked" : group.tier, "group__glyph"),
      h("span", { class: "group__text" },
        h("span", { class: "group__name", text: group.desc }),
        h("span", { class: "group__id", text: `${group.ruleId} · ${group.items.length}` })),
      h("span", { class: "group__sum" },
        h("span", { class: "group__bytes", text: size(state.lang, group.total) }),
        h("span", { class: "group__count", text: t(group.items.length === 1 ? "itemOne" : "itemMany", { n: number(state.lang, group.items.length, 0) }) })),
      glyph("chevron", "group__chev")),
    h("div", { class: "group__panel" },
      h("ul", { class: "group__items" },
        group.items.map((finding, idx) => renderRow(finding, idx, group, tab, stagger)))));
}

function animateList(before, after, node) {
  if (REDUCED.matches || Math.abs(after - before) < 2) return;
  node.style.overflow = "hidden";
  node.animate([{ height: `${before}px` }, { height: `${after}px` }], { duration: 520, easing: "cubic-bezier(0.16,1,0.3,1)" }).finished.finally(() => (node.style.overflow = ""));
}

function renderTab(tab, stagger) {
  const findings = tabFindings(tab);
  const node = { safe: dom.safeGroup, review: dom.reviewGroup, locked: dom.lockedGroup }[tab];
  const empty = { safe: dom.safeEmpty, review: dom.reviewEmpty, locked: dom.lockedEmpty }[tab];
  const meta = { safe: dom.safeMeta, review: dom.reviewMeta, locked: dom.lockedMeta }[tab];
  if (!node) return;
  const before = node.getBoundingClientRect().height;
  if (findings.length === 0) {
    node.replaceChildren();
    empty.hidden = false;
  } else {
    empty.hidden = true;
    const groups = groupByRule(findings);
    node.replaceChildren(...groups.map((g, i) => renderGroup(g, i, tab, stagger)));
  }
  meta.textContent = `${findings.length} · ${size(state.lang, findings.reduce((s, f) => s + f.bytes, 0))}`;
  const after = node.getBoundingClientRect().height;
  animateList(before, after, node);
}

function renderAllTabs(stagger) {
  renderTab("safe", stagger);
  renderTab("review", stagger);
  renderTab("locked", stagger);
}

function setTab(tab) {
  state.activeTab = tab;
  for (const id of TABS) {
    const btn = $({ safe: "tabSafeBtn", review: "tabReviewBtn", locked: "tabLockedBtn" }[id]);
    const panel = $({ safe: "tabSafe", review: "tabReview", locked: "tabLocked" }[id]);
    const selected = id === tab;
    btn.setAttribute("aria-selected", String(selected));
    panel.hidden = !selected;
  }
}

// `replaceChildren` discards the old nodes, which drops keyboard focus to
// <body>. Hand focus back to the control the user just activated.
function focusByKey(root, key) {
  const control = [...root.querySelectorAll("input[data-key]")].find((el) => el.dataset.key === key);
  if (control) control.focus();
}

function focusGroupHead(ruleId) {
  const head = [...document.querySelectorAll(".group__head")].find((el) => el.dataset.rule === ruleId);
  if (head) head.focus();
}

function toggleGroup(ruleId) {
  const current = state.openGroups.get(ruleId) ?? true;
  state.openGroups.set(ruleId, !current);
  renderAllTabs(false);
  focusGroupHead(ruleId);
}

// `/api/apply` answers with one tier per rule and `apply()` deletes every
// finding that carries it, so a per-item checkbox could only ever lie: tick one
// item of a rule and the engine removes its siblings the user never chose.
// Ticking therefore selects the whole rule — which is what the control's own
// `ruleWide` label already promised.
function toggleFinding(key, where = "row") {
  const finding = byKey.get(key);
  if (!finding) return;
  const group = state.report?.findings.filter((f) => f.ruleId === finding.ruleId && !isLocked(f)) ?? [];
  const select = !state.selected.has(key);
  for (const item of group) {
    if (select) state.selected.add(findingKey(item));
    else state.selected.delete(findingKey(item));
  }
  paintSummary();
  renderAllTabs(false);
  renderConfirm();
  focusByKey(where === "confirm" ? dom.confirmList : document, key);
}

function renderConfirm() {
  const deletable = state.report?.findings.filter((f) => !isLocked(f)) ?? [];
  const locked = state.report?.findings.filter(isLocked) ?? [];
  dom.confirmList.replaceChildren(...deletable.map((finding) => {
    const key = findingKey(finding);
    const checked = state.selected.has(key);
    return h("label", { class: "sheet__item", data: { tier: finding.tier } },
      h("input", { type: "checkbox", checked, "data-key": key, onclick: () => toggleFinding(key, "confirm") }),
      h("span", { class: "sheet__path", title: finding.path }, h("bdi", { text: finding.path })),
      h("b", { text: size(state.lang, finding.bytes) }),
      h("span", { class: "sheet__provenance", text: provenance(finding) }));
  }));
  const total = selectedBytes();
  dom.confirmTotal.textContent = t("confirmTotal", { amount: size(state.lang, total) });
  dom.confirmSelectedCount.textContent = t("confirmSelectedCount", { n: selectedCount() });
  dom.confirmLockedCount.textContent = t("confirmLockedCount", { n: locked.length });
  dom.confirmGo.disabled = state.selected.size === 0;
}

function openConfirm() {
  renderConfirm();
  dom.confirm.returnValue = "cancel";
  dom.confirm.showModal();
}

function setLanguage(code) {
  state.lang = code;
  localStorage.setItem(LANG_KEY, code);
  t = createTranslator(code);
  // The hero number is formatted per-locale; the byte count is unchanged, so
  // invalidate the memo or it would keep the previous language's separators.
  state.shownBytes = -1;
  paintText();
  paintStates();
  paintSummary();
  renderAllTabs(false);
}

function cycleTheme() {
  const order = ["system", "light", "dark"];
  const next = order[(order.indexOf(state.theme) + 1) % order.length];
  state.theme = next;
  paintTheme();
}

async function runScan() {
  state.status = "scanning";
  state.message = "";
  paintStates();
  paintSummary();
  startClock();
  try {
    const space = await api("/api/space").catch(() => null);
    if (space) {
      state.space = space;
      paintMeter();
    }
    const [report, rules] = await Promise.all([api("/api/scan"), api("/api/rules").catch(() => [])]);
    state.report = report;
    state.rules = rules;
    state.selected.clear();
    state.openGroups.clear();
    byKey.clear();
    for (const finding of report.findings) byKey.set(findingKey(finding), finding);

    state.status = report.findings.length ? "ready" : "empty";
    state.activeTab = "safe";
    dom.platformValue.textContent = report.platform;
    setTab("safe");
    renderAllTabs(true);
  } catch (error) {
    state.status = "error";
    state.message = error instanceof Error ? error.message : String(error);
    announce(`${t("errorTitle")}: ${state.message}`);
  } finally {
    clearInterval(clock);
    paintStates();
    paintSummary();
  }
}

// After a successful delete the report on screen is stale: deleted rows keep
// rendering and the hero keeps counting their bytes. Re-scan quietly, rebuild
// every derived structure, and drop the selection so the CTA cannot re-apply
// over paths that no longer exist. The caller keeps the result panel visible.
async function refreshAfterApply() {
  const fresh = await api("/api/scan").catch(() => null);
  if (!fresh) return;
  state.report = fresh;
  byKey.clear();
  for (const finding of fresh.findings) byKey.set(findingKey(finding), finding);
  state.selected.clear();
  state.openGroups.clear();
  dom.platformValue.textContent = fresh.platform;
  renderAllTabs(false);
}

async function runApply() {
  state.status = "working";
  paintStates();
  paintSummary();
  startClock();
  try {
    const report = await api("/api/apply", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ tiers: buildTierChoice() }),
    });
    state.space = { ...state.space, free: report.freeAfter };
    const counts = { deleted: 0, skipped: 0, failed: 0 };
    for (const outcome of report.outcomes) counts[outcome.status] += 1;
    const freed = heroSize(report.freed);
    state.status = "done";
    dom.outDeleted.textContent = number(state.lang, counts.deleted, 0);
    dom.outSkipped.textContent = number(state.lang, counts.skipped, 0);
    dom.outFailed.textContent = number(state.lang, counts.failed, 0);
    dom.outFree.textContent = size(state.lang, report.freeAfter);
    countUp(dom.freedValue, freed.value, (value) => number(state.lang, value, freed.digits), 2000);
    dom.freedUnit.textContent = freed.unit;
    paintMeter();
    await refreshAfterApply();
    announce(t("resultTitle"));
  } catch (error) {
    state.status = "ready";
    announce(`${t("applyErrorTitle")}: ${error instanceof Error ? error.message : String(error)}`);
  } finally {
    clearInterval(clock);
    paintStates();
    paintSummary();
  }
}

dom.langs.addEventListener("click", (event) => {
  const button = event.target.closest("[data-lang]");
  if (button) setLanguage(button.dataset.lang);
});
dom.themeBtn.addEventListener("click", cycleTheme);
dom.scanBtn.addEventListener("click", () => void runScan());
dom.retryBtn.addEventListener("click", () => void runScan());
dom.cleanBtn.addEventListener("click", openConfirm);
dom.confirmCancel.addEventListener("click", () => dom.confirm.close("cancel"));
dom.confirmGo.addEventListener("click", () => dom.confirm.close("confirm"));
dom.confirm.addEventListener("close", () => {
  if (dom.confirm.returnValue === "confirm") void runApply();
});

dom.tabSafeBtn.addEventListener("click", () => setTab("safe"));
dom.tabReviewBtn.addEventListener("click", () => setTab("review"));
dom.tabLockedBtn.addEventListener("click", () => setTab("locked"));

paintText();
paintTheme();
paintStates();
paintSummary();
void runScan();
