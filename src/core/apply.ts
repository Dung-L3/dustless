import { lstat, rm } from "node:fs/promises";
import { basename, parse, resolve, sep } from "node:path";
import type { ApplyOutcome, ApplyReport, Finding, Rule, ScanReport, TierChoice } from "../types.ts";
import { HOME, isRed, realGuard, refusalText, platform } from "./paths.ts";
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
    detail: "",
  };
  const guard = refusal(target);
  if (guard) {
    outcome.status = "failed";
    outcome.detail = guard;
    return outcome;
  }
  if (finding.blocked) {
    outcome.detail = `KIỆM SOÁT CHẶN: ${finding.note || "kiểm chứng thất bại"}`;
    return outcome;
  }
  if (opts.only && !opts.only.has(target)) {
    outcome.detail = "không được chọn: ngoài danh sách --only-file";
    return outcome;
  }
  const rule = rules.get(finding.ruleId);
  const native = rule?.nativeCommand?.trim().split(/\s+/)[0]?.toLowerCase() ?? "";
  const declared = (rule?.busyProcesses ?? (native ? BUSY_NAMES[native] ?? [native] : [])).map(processName);
  if (declared.length > 0) {
    const running = await busy();
    if (running === null) {
      outcome.detail = "không liệt kê được tiến trình đang chạy, bỏ qua để tránh hỏng tiến trình đang dùng";
      return outcome;
    }
    const watchers = declared.filter((name) =>
      running.entries.some((entry) => entry.name === name || entry.tools.has(name)),
    );
    if (watchers.length > 0) {
      outcome.detail = `${watchers.join(", ")} đang chạy, bỏ qua để tránh hỏng tiến trình đang dùng`;
      return outcome;
    }
  }
  const present = await lstat(target).then(() => true, (err: NodeJS.ErrnoException) => err.code !== "ENOENT");
  if (!present) {
    outcome.detail = "bỏ qua: đường dẫn không còn tồn tại";
    return outcome;
  }
  const chosen = Boolean(opts.tiers && Object.hasOwn(opts.tiers, finding.ruleId));
  const requested = chosen ? opts.tiers?.[finding.ruleId] ?? "skip" : "skip";
  const action = requested === "skip" ? "skip" : finding.tier === "yellow" ? "yellow" : requested;
  if (action === "skip") {
    outcome.detail = chosen ? "bỏ qua theo yêu cầu" : "bỏ qua: không được yêu cầu xoá";
    return outcome;
  }
  const recheck = await revalidate(finding, rule, target);
  if (recheck) {
    outcome.detail = recheck;
    return outcome;
  }
  if (action === "yellow" && !opts.assumeYes && !(await confirm(finding, opts))) {
    outcome.detail = opts.onPrompt ? "người dùng từ chối" : "cần xác nhận, chạy lại với --yes";
    return outcome;
  }
  const failure = await remove(target, opts.beforeDelete);
  outcome.status = failure ? "failed" : "deleted";
  outcome.bytes = failure ? 0 : finding.bytes;
  outcome.detail = failure;
  return outcome;
}

async function revalidate(finding: Finding, rule: Rule | undefined, target: string): Promise<string> {
  if (!rule) return "";
  const ageFloor = rule.minAgeDays;
  const staleFloor = rule.staleDays;
  const needsVerify = rule.requireVerify !== undefined;
  const needsGit = rule.gitClean === true;
  if (ageFloor === undefined && staleFloor === undefined && !needsVerify && !needsGit) return "";

  const measured = finding.mtime > 0;
  const needsTree = staleFloor !== undefined || (ageFloor !== undefined && measured);
  const tree = needsTree ? await treeUsage(target) : null;
  if (needsTree && tree === null) {
    return "bỏ qua: không đọc được cây thư mục để kiểm tra lại";
  }
  if (tree && staleFloor !== undefined) {
    const age = Math.max(0, (Date.now() - tree.mtime) / DAY);
    if (age < staleFloor) {
      return `bỏ qua: mới ${age.toFixed(1)} ngày, rule yêu cầu ≥ ${staleFloor} ngày`;
    }
  }
  if (tree && ageFloor !== undefined && measured && tree.mtime > finding.mtime) {
    const age = Math.max(0, (Date.now() - tree.mtime) / DAY);
    if (age < ageFloor) {
      return `bỏ qua: cây cache đã bị chạm sau lúc quét (mới ${age.toFixed(1)} ngày, rule yêu cầu ≥ ${ageFloor} ngày)`;
    }
  }
  if (needsGit) {
    const clean = await gitClean(target);
    if (!clean.ok) return `bỏ qua: ${clean.note}`;
  }
  if (needsVerify) {
    const verdict = await verify(rule, target);
    if (!verdict.ok) return `bỏ qua: ${verdict.note}`;
  }
  return "";
}

function refusal(path: string): string {
  const full = resolve(path);
  if (isRed(full)) return "từ chối: nằm trong danh sách đỏ";
  if (full === resolve(HOME) || resolve(HOME).startsWith(full + sep)) return "từ chối: là HOME hoặc thư mục cha của HOME";
  if (full === parse(full).root) return "từ chối: filesystem root";
  return "";
}

async function confirm(finding: Finding, opts: Options): Promise<boolean> {
  return (await opts.onPrompt?.(finding)) ?? false;
}

async function remove(path: string, beforeDelete?: () => void | Promise<void>): Promise<string> {
  const target = resolve(path);
  const first = realGuard(target);
  if ("refused" in first) return refusalText(first.refused);
  await beforeDelete?.();
  const attempts = platform === "win" ? 4 : 1;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    const again = realGuard(target);
    if ("refused" in again) return refusalText(again.refused);
    if (again.real !== first.real) return refusalText("changed");
    try {
      await rm(target, { recursive: true, force: true });
      return "";
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code ?? "EUNKNOWN";
      if (attempt === attempts || !RETRYABLE.has(code)) return `${code}: ${(err as Error).message}`;
      await Bun.sleep(200 * 2 ** attempt);
    }
  }
  return "";
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
