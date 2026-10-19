import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { createInterface } from "node:readline/promises";
import { apply } from "../core/apply.ts";
import { writeOut } from "../core/output.ts";
import { scan } from "../core/scan.ts";
import type { ApplyReport, Finding, ScanReport, TierChoice } from "../types.ts";
import { HUE, ICON, bold, bytesOf, dim, flag, paint, required, say, tierBadge } from "./context.ts";

async function printScan(report: ScanReport): Promise<void> {
  if (flag("json")) {
    await writeOut(`${JSON.stringify(report)}\n`);
    return;
  }
  say(bold(`\ndustless scan — ${report.platform} — ${report.scannedMs}ms — còn trống ${bytesOf(report.freeBefore)}\n`));
  if (!report.findings.length) {
    say(dim("Không có gì để dọn."));
    return;
  }
  for (const f of report.findings) {
    say(`${tierBadge(f.tier)} ${bytesOf(f.bytes).padStart(9)}  ${f.ageDays.toFixed(0)}d  ${f.ruleId}`);
    say(`    ${dim(f.path)}`);
    if (f.note) say(`    ${paint(HUE[f.tier], f.note)}`);
  }
  const { green, yellow } = report.totals;
  say(
    `\n${ICON.green} ${green.count} mục ${bytesOf(green.bytes)} · ${ICON.yellow} ${yellow.count} mục ${bytesOf(yellow.bytes)}` +
      ` · ${ICON.red} danh sách đỏ đã chặn\n${bold(`Thu hồi được ${bytesOf(report.reclaimable)}`)}\n`,
  );
}

async function printApply(result: ApplyReport): Promise<void> {
  if (flag("json")) {
    await writeOut(`${JSON.stringify(result)}\n`);
    return;
  }
  for (const o of result.outcomes) {
    const mark = o.status === "deleted" ? paint("32", "✔") : o.status === "failed" ? paint("31", "✖") : paint("33", "–");
    say(`${mark} ${bytesOf(o.bytes).padStart(9)}  ${dim(o.ruleId)}  ${o.path}`);
    if (o.detail) say(`  ${dim(o.detail)}`);
  }
  say(`\n${bold(`Đã thu hồi ${bytesOf(result.freed)}`)}`);
}

const idleApply = (): ApplyReport => ({
  outcomes: [],
  freed: 0,
  freeBefore: 0,
  freeAfter: 0,
  elapsedMs: 0,
});

export async function runScan(): Promise<number> {
  await printScan(await scan());
  return 0;
}

async function readSelection(): Promise<Set<string> | undefined> {
  if (!flag("only-file")) return undefined;
  const file = required("only-file", "dustless apply --only-file <selection.json>");
  let parsed: unknown;
  try {
    parsed = JSON.parse(await readFile(file, "utf8"));
  } catch (err) {
    throw new Error(`--only-file: không đọc được danh sách path từ "${file}": ${(err as Error).message}`);
  }
  if (!Array.isArray(parsed) || parsed.some((entry) => typeof entry !== "string")) {
    throw new Error(`--only-file: "${file}" phải là một mảng JSON các path tuyệt đối`);
  }
  return new Set((parsed as string[]).map((path) => resolve(path)));
}

export async function runApply(): Promise<number> {
  const only = await readSelection();
  const report = await scan();
  if (!flag("json")) await printScan(report);
  const deletable = report.findings.filter((f) => !f.blocked && f.tier !== "red");
  if (deletable.length === 0) {
    await printApply(idleApply());
    if (!flag("json")) say("Không có mục nào đủ điều kiện xóa.");
    return 0;
  }
  const selected = only ? deletable.filter((f) => only.has(resolve(f.path))) : deletable;
  if (!flag("yes") && !(await confirmSummary(selected, report.totals.blocked.count))) {
    await printApply(idleApply());
    if (!flag("json")) say("Đã hủy. Không có gì bị xóa.");
    return 0;
  }
  const result = await apply(report, { tiers: tierChoicesFor(report), assumeYes: flag("yes"), onPrompt: askYellow, only });
  await printApply(result);
  return result.outcomes.some((o) => o.status === "failed") ? 1 : 0;
}

function tierChoicesFor(report: ScanReport): TierChoice {
  const choices: TierChoice = {};
  for (const finding of report.findings) {
    if (finding.blocked || finding.tier === "red") continue;
    if (finding.tier === "yellow") choices[finding.ruleId] = "yellow";
    else if (!Object.hasOwn(choices, finding.ruleId)) choices[finding.ruleId] = "green";
  }
  return choices;
}

async function confirmSummary(findings: Finding[], blockedCount: number): Promise<boolean> {
  const green = findings.filter((f) => f.tier === "green");
  const yellow = findings.filter((f) => f.tier === "yellow");
  const total = findings.reduce((sum, f) => sum + f.bytes, 0);
  if (flag("json")) return false;
  say(
    `\n${bold("Sẽ xóa")} ${green.length} mục tự động (${bytesOf(green.reduce((s, f) => s + f.bytes, 0))})` +
      `\n${bold("Sẽ hỏi")}  ${yellow.length} mục (${bytesOf(yellow.reduce((s, f) => s + f.bytes, 0))})` +
      `\n${bold("Tổng")}   ${bytesOf(total)}`,
  );
  if (blockedCount > 0) {
    say(dim(`⛔ ${blockedCount} mục bị chặn, không thể xóa dù bạn xác nhận`));
  }
  if (!process.stdin.isTTY || flag("json")) return false;
  const answer = await createInterface({ input: process.stdin, output: process.stdout }).question(
    `\nXóa? [y/N] `,
  );
  return /^y/i.test(answer);
}

async function askYellow(finding: Finding): Promise<boolean> {
  if (flag("yes")) return true;
  if (!process.stdin.isTTY || flag("json")) return false;
  const answer = await createInterface({ input: process.stdin, output: process.stdout }).question(
    `\n${tierBadge(finding.tier)} xóa ${bytesOf(finding.bytes)} ở ${finding.path}? [y/N] `,
  );
  return /^y/i.test(answer);
}
