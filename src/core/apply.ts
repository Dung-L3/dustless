import { lstat, rm } from "node:fs/promises";
import { basename, parse, resolve, sep } from "node:path";
import type { ApplyOutcome, ApplyReport, Finding, Rule, ScanReport, TierChoice } from "../types.ts";
import { HOME, isRed, realGuard, refusalText, platform } from "./paths.ts";
import { loadRules } from "./rules.ts";
import { exec, freeSpace } from "./space.ts";

const RETRYABLE = new Set(["EBUSY", "EPERM", "EACCES", "ENOTEMPTY"]);
const BUSY_NAMES: Record<string, string[]> = {
  npm: ["npm"],
  npx: ["npx"],
  pnpm: ["pnpm"],
  yarn: ["yarn"],
};

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
  const busy = await runningCommands();
  const outcomes: ApplyOutcome[] = [];
  for (const finding of report.findings) {
    outcomes.push(await run(finding, opts, rules, busy));
  }
  const freeAfter = await freeSpace();
  return {
    outcomes,
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
  busy: Set<string>,
): Promise<ApplyOutcome> {
  const outcome: ApplyOutcome = {
    ruleId: finding.ruleId,
    tier: finding.tier,
    path: finding.path,
    status: "skipped",
    bytes: finding.bytes,
    detail: "",
  };
  const guard = refusal(finding.path);
  if (guard) {
    outcome.status = "failed";
    outcome.detail = guard;
    return outcome;
  }
  if (finding.blocked) {
    outcome.detail = `KIỆM SOÁT CHẶN: ${finding.note || "kiểm chứng thất bại"}`;
    return outcome;
  }
  if (opts.only && !opts.only.has(resolve(finding.path))) {
    outcome.detail = "không được chọn: ngoài danh sách --only-file";
    return outcome;
  }
  const rule = rules.get(finding.ruleId);
  const native = rule?.nativeCommand?.split(" ")[0]?.toLowerCase() ?? "";
  const declared = (rule?.busyProcesses ?? (native ? BUSY_NAMES[native] ?? [native] : [])).map((name) => basename(name.trim()).toLowerCase());
  const watchers = declared.filter((name) => busy.has(name));
  if (watchers.length > 0) {
    outcome.detail = `${watchers.join(", ")} đang chạy, bỏ qua để tránh hỏng tiến trình đang dùng`;
    return outcome;
  }
  const present = await lstat(finding.path).then(() => true, (err: NodeJS.ErrnoException) => err.code !== "ENOENT");
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
  if (action === "yellow" && !opts.assumeYes && !(await confirm(finding, opts))) {
    outcome.detail = opts.onPrompt ? "người dùng từ chối" : "cần xác nhận, chạy lại với --yes";
    return outcome;
  }
  const failure = await remove(finding.path, opts.beforeDelete);
  outcome.status = failure ? "failed" : "deleted";
  outcome.detail = failure;
  return outcome;
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

async function runningCommands(): Promise<Set<string>> {
  const run = await exec("ps", ["-Ao", "comm="]);
  return new Set(run.out.split("\n").map((line) => basename(line.trim().toLowerCase())));
}