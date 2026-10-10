#!/usr/bin/env bun
import { appendFile, mkdir, readdir } from "node:fs/promises";
import { homedir } from "node:os";
import { createInterface } from "node:readline/promises";
import type { ApplyOutcome, Finding, ScanReport, Tier } from "./types.ts";
import { HOME, exists, platform } from "./core/paths.ts";
import { configDir, loadRules, userRulesPath } from "./core/rules.ts";
import { scan } from "./core/scan.ts";
import { apply } from "./core/apply.ts";
import { diskUsage, freeSpace } from "./core/space.ts";
import { serveMcp } from "./mcp/server.ts";

const VERSION = "0.1.0";
const ICON: Record<Tier, string> = { green: "🟢", yellow: "🟡", red: "🔴", blocked: "⛔" };
const HUE: Record<Tier, string> = { green: "32", yellow: "33", red: "31", blocked: "35" };
const KEY_PATHS = [
  "~/.config/dustless",
  "~/.gradle/caches",
  "~/.npm/_cacache",
  "~/Library/Caches",
  "~/Library/Mail",
];
const HELP = `dustless ${VERSION} — dọn cache máy dev, không xóa mù

  dustless scan                 quét chéo, in ra những gì có thể dọn
  dustless apply                xóa GREEN, hỏi từng mục YELLOW
  dustless rule list|show|add|validate
  dustless mcp                 chạy MCP server trên stdio (cho AI agent)
  dustless doctor               chẩn đoán môi trường
  dustless version | help

Cờ chung: --json (máy đọc) --quiet (ít chữ) --yes (không hỏi)`;

const argv = process.argv.slice(2);
const args = argv.filter((arg) => !arg.startsWith("--"));
const flag = (name: string): boolean => argv.includes(`--${name}`);
const color = process.stdout.isTTY === true && !process.env["NO_COLOR"];
const paint = (hue: string, text: string): string => (color ? `\x1b[${hue}m${text}\x1b[0m` : text);
const bold = (text: string): string => paint("1", text);
const dim = (text: string): string => paint("2", text);

function bytesOf(n: number): string {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = n;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${unit === 0 ? value : value.toFixed(1)} ${units[unit] ?? "B"}`;
}

function tierBadge(tier: Tier): string {
  return paint(HUE[tier], `${ICON[tier]} ${tier.toUpperCase()}`);
}

function say(line = ""): void {
  if (!flag("quiet")) console.log(line);
}

function printScan(report: ScanReport): void {
  if (flag("json")) {
    console.log(JSON.stringify(report));
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

function printApply(outcomes: ApplyOutcome[], freed: number): void {
  if (flag("json")) {
    console.log(JSON.stringify({ outcomes, freed }));
    return;
  }
  for (const o of outcomes) {
    const mark = o.status === "deleted" ? paint("32", "✔") : o.status === "failed" ? paint("31", "✖") : paint("33", "–");
    say(`${mark} ${bytesOf(o.bytes).padStart(9)}  ${dim(o.ruleId)}  ${o.path}`);
    if (o.detail) say(`  ${dim(o.detail)}`);
  }
  say(`\n${bold(`Đã thu hồi ${bytesOf(freed)}`)}`);
}

async function runScan(): Promise<number> {
  printScan(await scan());
  return 0;
}

async function runApply(): Promise<number> {
  const report = await scan();
  if (!flag("json")) printScan(report);
  const result = await apply(report, { assumeYes: flag("yes"), onPrompt: askYellow });
  printApply(result.outcomes, result.freed);
  return result.outcomes.some((o) => o.status === "failed") ? 1 : 0;
}

async function askYellow(finding: Finding): Promise<boolean> {
  if (flag("yes")) return true;
  if (!process.stdin.isTTY || flag("json")) return false;
  const answer = await createInterface({ input: process.stdin, output: process.stdout }).question(
    `\n${tierBadge(finding.tier)} xóa ${bytesOf(finding.bytes)} ở ${finding.path}? [y/N] `,
  );
  return /^y/i.test(answer);
}

async function runRule(sub: string, rest: string[]): Promise<number> {
  if (sub === "list") {
    const rules = await loadRules();
    if (flag("json")) {
      console.log(JSON.stringify(rules));
      return 0;
    }
    for (const rule of rules) say(`${tierBadge(rule.tier)} ${rule.id.padEnd(26)} ${rule.desc}`);
    const source = (await exists(userRulesPath())) ? userRulesPath() : "default-rules.yaml";
    say(`\n${rules.length} rule · nguồn: ${source}`);
    return 0;
  }
  if (sub === "show") {
    const found = (await loadRules()).find((rule) => rule.id === rest[0]);
    if (!found) throw new Error(`không có rule "${rest[0] ?? ""}"`);
    console.log(JSON.stringify(found, null, 2));
    return 0;
  }
  if (sub === "add") {
    const [id, tier, desc, ...patterns] = rest;
    if (!id || !tier || !desc || !patterns.length) {
      throw new Error("dùng: dustless rule add <id> <green|yellow> <desc> <path>");
    }
    await mkdir(configDir(), { recursive: true });
    const paths = patterns.map((path) => `    all: ${JSON.stringify(path)}`).join("\n");
    await appendFile(userRulesPath(), `\n- id: ${id}\n  tier: ${tier}\n  desc: ${JSON.stringify(desc)}\n  paths:\n${paths}\n`);
    say(`đã thêm ${id} vào ${userRulesPath()} (${(await loadRules()).length} rule hợp lệ)`);
    return 0;
  }
  if (sub === "validate") {
    say(`OK — ${(await loadRules(rest[0])).length} rule hợp lệ`);
    return 0;
  }
  throw new Error(`rule: lệnh con không hợp lệ "${sub}"`);
}

async function probe(path: string): Promise<string> {
  const full = path.replace(/^~(?=$|[/\\])/, homedir());
  try {
    await readdir(full);
    return paint("32", "đọc được");
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code ?? "error";
    return code === "ENOENT" ? dim("không có") : paint("31", code);
  }
}

async function runDoctor(): Promise<number> {
  const usage = await diskUsage(HOME);
  const report = {
    platform,
    home: HOME,
    configDir: configDir(),
    rules: (await loadRules()).length,
    total: usage.bytes,
    free: await freeSpace(),
    paths: Object.fromEntries(await Promise.all(KEY_PATHS.map(async (p) => [p, await probe(p)] as const))),
  };
  if (flag("json")) {
    console.log(JSON.stringify(report, null, 2));
    return 0;
  }
  say(bold(`\ndustless doctor ${VERSION}`));
  for (const [key, value] of Object.entries(report).slice(0, 6)) {
    say(`  ${dim(key.padEnd(10))} ${typeof value === "number" && key !== "rules" ? bytesOf(value) : value}`);
  }
  say(bold("\n  đọc được các path"));
  for (const [path, state] of Object.entries(report.paths)) say(`  ${dim(path.padEnd(26))} ${state}`);
  const mail = report.paths["~/Library/Mail"] ?? "";
  say(
    mail.includes("EPERM") || mail.includes("EACCES")
      ? `\n${paint("31", "✖ thiếu Full Disk Access")} — cấp trong System Settings › Privacy & Security › Full Disk Access`
      : "\n" + paint("32", "✔ không thấy dấu hiệu thiếu Full Disk Access"),
  );
  return mail.includes("EPERM") ? 1 : 0;
}

async function main(): Promise<number> {
  const [command = "help", ...rest] = args;
  if (command === "scan") return await runScan();
  if (command === "apply") return await runApply();
  if (command === "rule") return await runRule(rest[0] ?? "", rest.slice(1));
  if (command === "doctor") return await runDoctor();
  if (command === "mcp") {
    await serveMcp();
    return 0;
  }
  if (command === "version") {
    console.log(flag("json") ? JSON.stringify({ version: VERSION }) : VERSION);
    return 0;
  }
  if (command === "help" || flag("help")) {
    console.log(HELP);
    return 0;
  }
  throw new Error(`lệnh không hợp lệ "${command}" — chạy \`dustless help\``);
}

process.on("unhandledRejection", (reason) => {
  console.error(paint("31", String(reason)));
  process.exit(1);
});

main().then(
  (code) => {
    process.exitCode = code;
  },
  (err: Error) => {
    console.error(paint("31", `✖ ${err.message}`));
    process.exitCode = 1;
  },
);