import { createTranslator } from "./i18n.js";

const STORAGE_KEY = "dustless.lang";
const KIB = 1024;
const MIB = KIB ** 2;
const GIB = KIB ** 3;
const SVG_NS = "http://www.w3.org/2000/svg";
const REDUCED = matchMedia("(prefers-reduced-motion: reduce)");
const OPEN_BY_DEFAULT = 5;
const $ = (id) => document.getElementById(id);

const dom = {
  langs: $("langs"), diskMeter: $("diskMeter"), diskFill: $("diskFill"),
  reclaimValue: $("reclaimValue"), reclaimUnit: $("reclaimUnit"),
  freeValue: $("freeValue"), usedPercent: $("usedPercent"),
  cleanBtn: $("cleanBtn"), cleanHint: $("cleanHint"), scanBtn: $("scanBtn"),
  findMeta: $("findMeta"), groups: $("groups"),
  scanState: $("scanState"), scanTitle: $("scanTitle"), scanBody: $("scanBody"), scanClock: $("scanClock"),
  emptyState: $("emptyState"), emptyTitle: $("emptyTitle"), emptyBody: $("emptyBody"),
  errorState: $("errorState"), errorTitle: $("errorTitle"), errorBody: $("errorBody"),
  retryBtn: $("retryBtn"), platformValue: $("platformValue"),
  result: $("result"), resultTitle: $("resultTitle"), resultBody: $("resultBody"),
  freedValue: $("freedValue"), freedUnit: $("freedUnit"),
  outDeleted: $("outDeleted"), outSkipped: $("outSkipped"), outFailed: $("outFailed"), outFree: $("outFree"),
  confirm: $("confirm"), confirmBody: $("confirmBody"), confirmList: $("confirmList"),
  confirmTotal: $("confirmTotal"), toast: $("toast"),
};

const state = {
  lang: readStoredLanguage(),
  status: "scanning",
  report: null,
  rules: [],
  space: { free: 0, total: 0 },
  declinedRules: new Set(),
  openOverrides: new Map(),
  message: "",
  shownBytes: -1,
};

const byKey = new Map();
let groups = [];
let t = createTranslator(state.lang);
let clock = 0;
let toastTimer = 0;

function readStoredLanguage() {
  const stored = localStorage.getItem(STORAGE_KEY);
  return ["vi", "en", "zh"].includes(stored) ? stored : "en";
}

function h(tag, props, ...kids) {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(props ?? {})) {
    if (value === undefined || value === null || value === false) continue;
    if (name === "class") node.className = value;
    else if (name === "text") node.textContent = value;
    else if (name === "data") Object.entries(value).forEach(([k, v]) => (node.dataset[k] = v));
    else if (name === "style") Object.entries(value).forEach(([k, v]) => node.style.setProperty(k, v));
    else if (name.startsWith("on")) node.addEventListener(name.slice(2).toLowerCase(), value);
    else node.setAttribute(name, value);
  }
  for (const kid of kids.flat()) if (kid !== null && kid !== undefined && kid !== false) node.append(kid);
  return node;
}

function glyph(name, className) {
  const svg = document.createElementNS(SVG_NS, "svg");
  if (className) svg.setAttribute("class", className);
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(SVG_NS, "use");
  use.setAttribute("href", `#i-${name}`);
  svg.append(use);
  return svg;
}

function number(value, digits) {
  return new Intl.NumberFormat(state.lang, {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  }).format(value);
}

function size(bytes) {
  if (bytes >= GIB) return `${number(bytes / GIB, bytes >= 10 * GIB ? 0 : 1)} GB`;
  if (bytes >= MIB) return `${number(bytes / MIB, 0)} MB`;
  if (bytes >= KIB) return `${number(bytes / KIB, 0)} KB`;
  return `${number(bytes, 0)} B`;
}

function heroSize(bytes) {
  if (bytes < MIB) return { value: bytes / MIB, unit: "GB", digits: 2 };
  if (bytes >= GIB) {
    const raw = bytes / GIB;
    return { value: raw, unit: "GB", digits: raw >= 10 ? 1 : 2 };
  }
  return { value: bytes / MIB, unit: "MB", digits: 0 };
}

function clockLabel(ms) {
  return ms < 1000 ? `${number(ms, 0)}ms` : `${number(ms / 1000, 1)}s`;
}

function countUp(node, to, format, duration = 1500) {
  if (REDUCED.matches) {
    node.textContent = format(to);
    return;
  }
  const start = performance.now();
  const frame = (now) => {
    const progress = Math.min(1, (now - start) / duration);
    node.textContent = format(to * (1 - (1 - progress) ** 4));
    if (progress < 1) requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
}

async function api(path, options) {
  const response = await fetch(path, options);
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error ?? `HTTP ${response.status}`);
  return payload;
}

function findingKey(finding) {
  return `${finding.ruleId} :: ${finding.path}`;
}

function isApproved(finding) {
  if (finding.tier === "green") return true;
  if (finding.tier === "red") return false;
  return !state.declinedRules.has(finding.ruleId);
}

function buildGroups(report) {
  const buckets = new Map();
  for (const finding of report.findings) {
    if (!buckets.has(finding.ruleId)) buckets.set(finding.ruleId, []);
    buckets.get(finding.ruleId).push(finding);
  }
  return [...buckets.entries()]
    .map(([ruleId, items]) => {
      const sorted = items.sort((a, b) => b.bytes - a.bytes);
      return {
        ruleId,
        tier: sorted[0].tier,
        desc: sorted[0].desc,
        items: sorted,
        widest: sorted[0].bytes,
        total: sorted.reduce((sum, item) => sum + item.bytes, 0),
      };
    })
    .sort((a, b) => b.total - a.total);
}

function tierChoices() {
  const choices = {};
  for (const group of groups) {
    choices[group.ruleId] =
      group.tier === "green" ? "green"
      : group.tier === "red" ? "skip"
      : group.items.some(isApproved) ? "yellow"
      : "skip";
  }
  return choices;
}

function selection() {
  const entries = [];
  let bytes = 0;
  for (const group of groups) {
    for (const finding of group.items) {
      if (!isApproved(finding)) continue;
      entries.push(finding);
      bytes += finding.bytes;
    }
  }
  return { entries: entries.sort((a, b) => b.bytes - a.bytes), bytes };
}

function announce(text) {
  dom.toast.textContent = text;
  dom.toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (dom.toast.hidden = true), 4200);
}

function paintText() {
  document.documentElement.lang = state.lang;
  dom.langs.setAttribute("aria-label", t("language"));
  for (const button of dom.langs.querySelectorAll("[data-lang]")) {
    button.setAttribute("aria-pressed", String(button.dataset.lang === state.lang));
  }
  for (const node of document.querySelectorAll("[data-i18n]")) node.textContent = t(node.dataset.i18n);
}

function paintMeter() {
  const { free, total } = state.space;
  if (!total) return;
  dom.diskFill.style.setProperty("--used", String(Math.min(1, (total - free) / total)));
  dom.freeValue.textContent = size(free);
  dom.usedPercent.textContent = `${number(((total - free) / total) * 100, 0)}%`;
  dom.diskMeter.setAttribute("aria-label", `${t("freeSpace")}: ${size(free)}`);
}

function metaLine() {
  if (!state.report) return "";
  const parts = [
    t("foundMeta", {
      items: number(state.report.findings.length, 0),
      rules: number(groups.length, 0),
      ms: clockLabel(state.report.scannedMs),
    }),
  ];
  if (state.rules.length) {
    const counts = { green: 0, yellow: 0, red: 0 };
    for (const rule of state.rules) counts[rule.tier] += 1;
    parts.push(t("rulesActive", counts));
  }
  return parts.join(" · ");
}

function paintSummary() {
  const chosen = selection();
  const pending = state.status === "scanning";
  const shown = state.status === "empty" ? 0 : chosen.bytes;
  if (shown !== state.shownBytes) {
    state.shownBytes = shown;
    const hero = heroSize(shown);
    countUp(dom.reclaimValue, hero.value, (value) => number(value, hero.digits));
    dom.reclaimUnit.textContent = hero.unit;
  }
  const totals = state.report?.totals ?? {};
  for (const tier of ["green", "yellow", "red"]) {
    $(`${tier}Count`).textContent = number(totals[tier]?.count ?? 0, 0);
    $(`${tier}Size`).textContent = size(totals[tier]?.bytes ?? 0);
  }
  dom.cleanBtn.disabled = pending || chosen.entries.length === 0;
  dom.cleanHint.textContent =
    pending ? t("scanningHint")
    : chosen.entries.length === 0 ? t("cleanHintNone")
    : `${number(chosen.entries.length, 0)} · ${size(chosen.bytes)}`;
  dom.scanBtn.dataset.busy = String(pending);
  dom.findMeta.textContent = metaLine();
}

function paintStates() {
  const busy = state.status === "scanning" || state.status === "working";
  dom.scanState.hidden = !busy;
  dom.emptyState.hidden = state.status !== "empty";
  dom.errorState.hidden = state.status !== "error";
  dom.result.hidden = state.status !== "done";
  dom.groups.hidden = busy || state.status === "error";
  dom.scanTitle.textContent = t(state.status === "working" ? "working" : "scanning");
  dom.scanBody.textContent = t(state.status === "working" ? "workingHint" : "scanningHint");
  dom.emptyTitle.textContent = t("emptyTitle");
  dom.emptyBody.textContent = t("emptyBody");
  dom.errorTitle.textContent = t("errorTitle");
  dom.errorBody.textContent = t("errorBody", { message: state.message });
  dom.resultTitle.textContent = t("resultTitle");
  dom.resultBody.textContent = t("resultBody");
  dom.confirmBody.textContent = t("confirmBody");
}

function startClock() {
  const started = performance.now();
  clearInterval(clock);
  clock = setInterval(() => {
    dom.scanClock.textContent = t("elapsed", { s: clockLabel(performance.now() - started) });
  }, 120);
  dom.scanClock.textContent = t("elapsed", { s: clockLabel(0) });
}

function renderRow(finding, index, group, stagger) {
  const tag = (muted) => h("span", { class: muted ? "row__tag row__tag--muted" : "row__tag" }, glyph(finding.tier), t(finding.tier));
  return h("div", {
    class: "row",
    data: { tier: finding.tier, decision: findingKey(finding), chosen: String(isApproved(finding)) },
    style: { "--i": String(stagger ? Math.min(index, 12) : 0) },
  },
    h("div", { class: "row__main" },
      h("p", { class: "row__path", title: finding.path }, h("bdi", { text: finding.path })),
      h("div", { class: "row__meta" },
        tag(finding.tier !== "yellow"),
        h("span", { text: t(finding.verified ? "verified" : "unverified") }),
        h("span", { text: t("ageDays", { n: Math.round(finding.ageDays) }) }),
        finding.note ? h("span", { text: finding.note }) : null)),
    h("div", { class: "row__right" },
      h("span", { class: "row__bytes", text: size(finding.bytes) }),
      h("div", { class: "bar", style: { "--w": String(group.widest ? finding.bytes / group.widest : 0) } },
        h("span", { class: "bar__fill" }))),
    decision(finding));
}

function decision(finding) {
  if (finding.tier === "red") {
    return h("div", { class: "decision" }, h("p", { class: "decision__hint", text: t("blocked") }));
  }
  if (finding.tier !== "yellow") return null;
  const on = isApproved(finding);
  const choice = (key, iconName, label, press, approve) => h("button", {
    type: "button", "aria-pressed": String(press), data: { choice: key },
    onclick: () => choose(finding, approve),
  }, glyph(iconName), label);
  return h("div", { class: "decision" },
    h("div", { class: "switch", role: "group", "aria-label": t("ruleWide") },
      choice("delete", "broom", t("delete"), on, true),
      choice("keep", "lock", t("keep"), !on, false)),
    h("p", { class: "decision__hint", text: on ? t("willDelete") : t("kept") }));
}

function renderGroup(group, index, stagger) {
  const open = state.openOverrides.get(group.ruleId) ?? index < OPEN_BY_DEFAULT;
  return h("div", {
    class: "group",
    data: { tier: group.tier, open: String(open) },
    style: { "--i": String(stagger ? Math.min(index, 10) : 0) },
  },
    h("button", {
      type: "button", class: "group__head", "aria-expanded": String(open),
      "aria-label": t(open ? "collapseGroup" : "expandGroup"),
      onclick: (event) => toggle(group.ruleId, event.currentTarget),
    },
      glyph(group.tier, "group__glyph"),
      h("span", { class: "group__text" },
        h("span", { class: "group__name", text: group.desc }),
        h("span", { class: "group__id", text: `${group.ruleId} · ${group.items.length}` })),
      h("span", { class: "group__sum" },
        h("span", { class: "group__bytes", text: size(group.total) }),
        h("span", { class: "group__count", text: t(group.items.length === 1 ? "itemOne" : "itemMany", { n: number(group.items.length, 0) }) })),
      glyph("chevron", "group__chev")),
    h("div", { class: "group__panel" },
      h("ul", { class: "group__items" },
        group.items.map((finding, index) => renderRow(finding, index, group, stagger)))));
}

function renderGroups(stagger) {
  const before = dom.groups.getBoundingClientRect().height;
  dom.groups.replaceChildren(...groups.map((group, index) => renderGroup(group, index, stagger)));
  const after = dom.groups.getBoundingClientRect().height;
  if (REDUCED.matches || Math.abs(after - before) < 2) return;
  dom.groups.style.overflow = "hidden";
  dom.groups.animate([{ height: `${before}px` }, { height: `${after}px` }], {
    duration: 520,
    easing: "cubic-bezier(0.16,1,0.3,1)",
  }).finished.finally(() => (dom.groups.style.overflow = ""));
}

function toggle(ruleId, button) {
  const open = button.closest(".group").dataset.open === "true";
  state.openOverrides.set(ruleId, !open);
  button.setAttribute("aria-expanded", String(!open));
  button.setAttribute("aria-label", t(!open ? "collapseGroup" : "expandGroup"));
  button.closest(".group").dataset.open = String(!open);
}

function choose(finding, approve) {
  if (approve) state.declinedRules.delete(finding.ruleId);
  else state.declinedRules.add(finding.ruleId);
  syncChoices();
}

function syncChoices() {
  for (const row of dom.groups.querySelectorAll(".row[data-decision]")) {
    const finding = byKey.get(row.dataset.decision);
    if (!finding) continue;
    const on = isApproved(finding);
    row.dataset.chosen = String(on);
    for (const button of row.querySelectorAll(".switch button")) {
      button.setAttribute("aria-pressed", String((button.dataset.choice === "delete") === on));
    }
    const hint = row.querySelector(".decision__hint");
    if (hint) hint.textContent = on ? t("willDelete") : t("kept");
  }
  paintSummary();
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
    state.declinedRules.clear();
    state.openOverrides.clear();
    groups = buildGroups(report);
    byKey.clear();
    for (const group of groups) for (const finding of group.items) byKey.set(findingKey(finding), finding);
    state.status = groups.length ? "ready" : "empty";
    dom.platformValue.textContent = report.platform;
    renderGroups(true);
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

async function runApply() {
  state.status = "working";
  paintStates();
  startClock();
  try {
    const report = await api("/api/apply", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ tiers: tierChoices() }),
    });
    state.space = { ...state.space, free: report.freeAfter };
    const counts = { deleted: 0, skipped: 0, failed: 0 };
    for (const outcome of report.outcomes) counts[outcome.status] += 1;
    const freed = heroSize(report.freed);
    state.status = "done";
    dom.outDeleted.textContent = number(counts.deleted, 0);
    dom.outSkipped.textContent = number(counts.skipped, 0);
    dom.outFailed.textContent = number(counts.failed, 0);
    dom.outFree.textContent = size(report.freeAfter);
    countUp(dom.freedValue, freed.value, (value) => number(value, freed.digits), 2000);
    dom.freedUnit.textContent = freed.unit;
    paintMeter();
    announce(t("resultTitle"));
  } catch (error) {
    state.status = "ready";
    announce(`${t("errorTitle")}: ${error instanceof Error ? error.message : String(error)}`);
  } finally {
    clearInterval(clock);
    paintStates();
    paintSummary();
  }
}

function openConfirm() {
  const chosen = selection();
  dom.confirmList.replaceChildren(...chosen.entries.map((finding) =>
    h("li", { class: "sheet__item", data: { tier: finding.tier } },
      glyph(finding.tier),
      h("span", { title: finding.path }, h("bdi", { text: finding.path })),
      h("b", { text: size(finding.bytes) }))));
  dom.confirmTotal.textContent = t("confirmTotal", { amount: size(chosen.bytes) });
  dom.confirm.returnValue = "cancel";
  dom.confirm.showModal();
}

function setLanguage(code) {
  state.lang = code;
  localStorage.setItem(STORAGE_KEY, code);
  t = createTranslator(code);
  paintText();
  paintStates();
  paintSummary();
  renderGroups(false);
}

dom.langs.addEventListener("click", (event) => {
  const button = event.target.closest("[data-lang]");
  if (button) setLanguage(button.dataset.lang);
});
dom.cleanBtn.addEventListener("click", openConfirm);
dom.scanBtn.addEventListener("click", () => void runScan());
dom.retryBtn.addEventListener("click", () => void runScan());
dom.confirm.addEventListener("close", () => {
  if (dom.confirm.returnValue === "confirm") void runApply();
});

paintText();
paintStates();
paintSummary();
void runScan();