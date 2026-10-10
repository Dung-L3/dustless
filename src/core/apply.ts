import { rm } from "node:fs/promises";
import { basename, parse, resolve, sep } from "node:path";
import type { ApplyOutcome, ApplyReport, Finding, Rule, ScanReport, TierChoice } from "../types.ts";
import { HOME, isRed, platform } from "./paths.ts";
import { loadRules } from "./rules.ts";
import { exec, freeSpace } from "./space.ts";

const RETRYABLE = new Set(["EBUSY", "EPERM", "EACCES", "ENOTEMPTY"]);
const BUSY_NAMES: Record<string, string[]> = {
  npm: ["npm", "node"],
  npx: ["npx", "node"],
  pnpm: ["pnpm", "node"],
  yarn: ["yarn", "node"],
};

type Options = {
  tiers?: TierChoice;
  assumeYes?: boolean;
  onPrompt?: (finding: Finding) => Promise<boolean>;
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
  const rule = rules.get(finding.ruleId);
  const native = rule?.nativeCommand?.split(" ")[0]?.toLowerCase() ?? "";
  if (native && (BUSY_NAMES[native] ?? [native]).some((name) => busy.has(name))) {
    outcome.detail = `${rule?.nativeCommand} đang chạy`;
    return outcome;
  }
  const action = opts.tiers?.[finding.ruleId] ?? (finding.tier === "green" ? "green" : "yellow");
  if (action === "skip") {
    outcome.detail = "bỏ qua theo yêu cầu";
    return outcome;
  }
  if (action === "yellow" && !opts.assumeYes && !(await confirm(finding, opts))) {
    outcome.detail = opts.onPrompt ? "người dùng từ chối" : "cần xác nhận, chạy lại với --yes";
    return outcome;
  }
  const failure = await remove(finding.path);
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

async function remove(path: string): Promise<string> {
  const attempts = platform === "win" ? 4 : 1;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      await rm(path, { recursive: true, force: true });
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