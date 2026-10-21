import { lstat, rm } from "node:fs/promises";
import { basename, parse, resolve, sep } from "node:path";
import type { ApplyOutcome, ApplyReport, Finding, Reason, Rule, ScanReport, TierChoice } from "../types.ts";
import { SCHEMA_VERSION } from "../types.ts";
import { HOME, isRed, realGuard, refusalCode, platform } from "./paths.ts";
import { loadRules } from "./rules.ts";
import { accountedBytes, exec, freeSpace, treeUsage } from "./space.ts";
import { verify } from "./verify/index.ts";
import { gitClean } from "./verify/git.ts";

const DAY = 86_400_000;
const RETRYABLE = new Set(["EBUSY", "EPERM", "EACCES", "ENOTEMPTY"]);
const BUSY_NAMES: Record<string, string[]> = {
  npm: ["npm"],
  npx: ["npx"],
  pnpm: ["pnpm"],
  yarn: ["yarn"],
};

const TOOL_PATTERNS: { tool: string; pattern: RegExp }[] = [
  { tool: "gradle", pattern: /(^|[\s/\\])gradle([\s/\\.-]|$)|gradledaemon|org\.gradle\./i },
  { tool: "npx", pattern: /(^|[\s/\\])npx([\s/\\]|$)|npm\s+exec(\s|$)|npm-cli\.js\s+exec(\s|$)/ },
  { tool: "pnpm", pattern: /(^|[\s/\\])pnpm(\.[cm]?js)?([\s/\\]|$)/ },
  { tool: "yarn", pattern: /(^|[\s/\\])yarn(\.[cm]?js)?([\s/\\]|$)/ },
  { tool: "npm", pattern: /(^|[\s/\\])npm(-cli)?(\.[cm]?js)?([\s/\\]|$)/ },
];


type ProcessEntry = { name: string; tools: Set<string> };
type Listing = { entries: ProcessEntry[] };

function processName(name: string): string {
  return basename(name.replace(/\\/g, "/").trim().toLowerCase()).replace(/\.exe$/, "");
}

type Options = {
  tiers?: TierChoice;
  assumeYes?: boolean;
  onPrompt?: (finding: Finding) => Promise<boolean>;
  only?: ReadonlySet<string>;
  beforeDelete?: () => void | Promise<void>;
};

export async function apply(report: ScanReport, opts: Options = {}): Promise<ApplyReport> {
  const started = Date.now();
  const rules = new Map((await loadRules()).map((rule) => [rule.id, rule]));
  let listing: Listing | null | undefined;
  const busy = async (): Promise<Listing | null> => {
    if (listing === undefined) listing = await runningCommands();
    return listing;
  };
  const outcomes: ApplyOutcome[] = [];
  for (const finding of report.findings) {
    outcomes.push(await run(finding, opts, rules, busy));
  }
  const freeAfter = await freeSpace();
  const deleted = outcomes.filter((outcome) => outcome.status === "deleted");
  return {
    schemaVersion: SCHEMA_VERSION,
    outcomes,
    deletedBytes: accountedBytes(deleted.map((outcome) => ({ path: outcome.path, bytes: outcome.bytes }))),
    freed: Math.max(0, freeAfter - report.freeBefore),
    freeBefore: report.freeBefore,
    freeAfter,
    elapsedMs: Date.now() - started,
  };
}

async function run(
  finding: Finding,
  opts: Options,
  rules: Map<string, Rule>,
  busy: () => Promise<Listing | null>,
): Promise<ApplyOutcome> {
  const target = resolve(finding.path);
  const outcome: ApplyOutcome = {
    ruleId: finding.ruleId,
    tier: finding.tier,
    path: target,
    status: "skipped",
    bytes: 0,
    detail: null,
  };
  const guard = refusal(target);
  if (guard) {
    outcome.status = "failed";
    outcome.detail = guard;
    return outcome;
  }
  if (finding.blocked) {
    outcome.detail = { code: "verify_failed", params: { cause: finding.note[0]?.params?.cause ?? "unknown" } };
    return outcome;
  }
  if (opts.only && !opts.only.has(target)) {
    outcome.detail = { code: "not_selected" };
    return outcome;
  }
  const rule = rules.get(finding.ruleId);
  const native = rule?.nativeCommand?.trim().split(/\s+/)[0]?.toLowerCase() ?? "";
  const declared = (rule?.busyProcesses ?? (native ? BUSY_NAMES[native] ?? [native] : [])).map(processName);
  if (declared.length > 0) {
    const running = await busy();
    if (running === null) {
      outcome.detail = { code: "listing_unavailable" };
      return outcome;
    }
    const watchers = declared.filter((name) =>
      running.entries.some((entry) => entry.name === name || entry.tools.has(name)),
    );
    if (watchers.length > 0) {
      outcome.detail = { code: "busy_process", params: { names: watchers.join(", ") } };
      return outcome;
    }
  }
  const present = await lstat(target).then(() => true, (err: NodeJS.ErrnoException) => err.code !== "ENOENT");
  if (!present) {
    outcome.detail = { code: "missing" };
    return outcome;
  }
  const chosen = Boolean(opts.tiers && Object.hasOwn(opts.tiers, finding.ruleId));
  const requested = chosen ? opts.tiers?.[finding.ruleId] ?? "skip" : "skip";
  const action = requested === "skip" ? "skip" : finding.tier === "yellow" ? "yellow" : requested;
  if (action === "skip") {
    outcome.detail = { code: "not_selected" };
    return outcome;
  }
  const recheck = await revalidate(finding, rule, target);
  if (recheck) {
    outcome.detail = recheck;
    return outcome;
  }
  if (action === "yellow" && !opts.assumeYes && !(await confirm(finding, opts))) {
    outcome.detail = { code: opts.onPrompt ? "declined" : "needs_confirmation" };
    return outcome;
  }
  const failure = await remove(target, opts.beforeDelete);
  outcome.status = failure ? "failed" : "deleted";
  outcome.bytes = failure ? 0 : finding.bytes;
  outcome.detail = failure;
  return outcome;
}

async function revalidate(finding: Finding, rule: Rule | undefined, target: string): Promise<Reason | null> {
  if (!rule) return null;
  const ageFloor = rule.minAgeDays;
  const staleFloor = rule.staleDays;
  const needsVerify = rule.requireVerify !== undefined;
  const needsGit = rule.gitClean === true;
  if (ageFloor === undefined && staleFloor === undefined && !needsVerify && !needsGit) return null;

  const measured = finding.mtime > 0;
  const needsTree = staleFloor !== undefined || (ageFloor !== undefined && measured);
  const tree = needsTree ? await treeUsage(target) : null;
  if (needsTree && tree === null) {
    return { code: "unresolvable" };
  }
  if (tree && staleFloor !== undefined) {
    const age = Math.max(0, (Date.now() - tree.mtime) / DAY);
    if (age < staleFloor) {
      return { code: "stale_days", params: { age: age.toFixed(1), min: String(staleFloor) } };
    }
  }
  if (tree && ageFloor !== undefined && measured && tree.mtime > finding.mtime) {
    const age = Math.max(0, (Date.now() - tree.mtime) / DAY);
    if (age < ageFloor) {
      return { code: "revalidate_age", params: { age: age.toFixed(1), min: String(ageFloor) } };
    }
  }
  if (needsGit) {
    const clean = await gitClean(target);
    if (!clean.ok) return { code: "revalidate_verify", params: { cause: clean.cause ?? "unknown" } };
  }
  if (needsVerify) {
    const verdict = await verify(rule, target);
    if (!verdict.ok) return { code: "revalidate_verify", params: { cause: verdict.cause ?? "unknown" } };
  }
  return null;
}

function refusal(path: string): Reason | null {
  const full = resolve(path);
  if (isRed(full)) return { code: "red_list" };
  if (full === resolve(HOME) || resolve(HOME).startsWith(full + sep)) return { code: "home" };
  if (full === parse(full).root) return { code: "root" };
  return null;
}

async function confirm(finding: Finding, opts: Options): Promise<boolean> {
  return (await opts.onPrompt?.(finding)) ?? false;
}

async function remove(path: string, beforeDelete?: () => void | Promise<void>): Promise<Reason | null> {
  const target = resolve(path);
  const first = realGuard(target);
  if ("refused" in first) return { code: refusalCode(first.refused) };
  await beforeDelete?.();
  const attempts = platform === "win" ? 4 : 1;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    const again = realGuard(target);
    if ("refused" in again) return { code: refusalCode(again.refused) };
    if (again.real !== first.real) return { code: "changed" };
    try {
      await rm(target, { recursive: true, force: true });
      return null;
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code ?? "EUNKNOWN";
      if (attempt === attempts || !RETRYABLE.has(code)) {
        return { code: "io_error", params: { code, message: (err as Error).message } };
      }
      await Bun.sleep(200 * 2 ** attempt);
    }
  }
  return null;
}

async function runningCommands(): Promise<Listing | null> {
  const posix = await exec("ps", ["-Ao", "args="]);
  if (posix.code === 0) {
    const entries = parseListing(posix.out, false);
    if (entries.length > 0) return { entries };
  }
  const win = await exec("tasklist", ["/fo", "csv", "/nh"]);
  if (win.code === 0) {
    const entries = parseListing(win.out, true);
    if (entries.length > 0) return { entries };
  }
  return null;
}

function parseListing(out: string, csv: boolean): ProcessEntry[] {
  return out
    .split("\n")
    .map((line) => (csv ? line.trim().match(/^"([^"]+)"/)?.[1] ?? "" : line.trim()))
    .filter(Boolean)
    .map((line) => classify(line, csv));
}

function classify(line: string, csv: boolean): ProcessEntry {
  const command = line.toLowerCase();
  const tools = new Set<string>();
  for (const { tool, pattern } of TOOL_PATTERNS) {
    if (tool === "npm" && tools.has("npx")) continue;
    if (pattern.test(command)) tools.add(tool);
  }
  const head = csv ? line : line.split(/\s+/)[0] ?? "";
  let name = processName(head);
  if (name === "npm" && tools.has("npx")) name = "npx";
  return { name, tools };
}
