#!/usr/bin/env bun
import { appendFile, mkdir, readdir } from "node:fs/promises";
import pkg from "../package.json" with { type: "json" };
import { homedir } from "node:os";
import { createInterface } from "node:readline/promises";
import type { ApplyReport, Finding, ScanReport, Tier, TierChoice } from "./types.ts";
import { HOME, exists, platform } from "./core/paths.ts";
import { inspectSystem } from "./system/index.ts";
import { configDir, loadRules, userRulesPath } from "./core/rules.ts";
import { scan } from "./core/scan.ts";
import { apply } from "./core/apply.ts";
import { diskUsage, freeSpace } from "./core/space.ts";
import { net, selectOps, type NetFlags, type NetReport } from "./core/net/index.ts";
import { serveMcp } from "./mcp/server.ts";
import { runRam } from "./core/ram/index.ts";
import { writeOut } from "./core/output.ts";
import { listApps, uninstall } from "./core/apps/index.ts";

const VERSION = pkg.version;
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
  dustless ui [--port 4173]     mở giao diện web cục bộ
  dustless apply                xóa GREEN, hỏi từng mục YELLOW
  dustless rule list|show|add|validate
  dustless mcp                 chạy MCP server trên stdio (cho AI agent)
  dustless doctor               chẩn đoán môi trường
  dustless net                  flush DNS cache; --reset-dns v.v. là nâng cao, từng lệnh một
  dustless ram [--list]         quản lý bộ nhớ (chỉ xem, không tự động hành động)
  dustless apps [--json]        liệt kê ứng dụng .app
  dustless apps --uninstall <path> --confirm [--purge] [--json]  gỡ ứng dụng (di chuyển đến Thùng rác)
  dustless version | help

Cờ chung: --json (máy đọc) --quiet (ít chữ) --yes (không hỏi)`;

const argv = process.argv.slice(2);
const args = argv.filter((arg) => !arg.startsWith("--"));
const flag = (name: string): boolean => argv.includes(`--${name}`);
const opt = (name: string): string | undefined => {
  const at = argv.indexOf(`--${name}`);
  return at >= 0 ? argv[at + 1] : undefined;
};
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

async function runScan(): Promise<number> {
  await printScan(await scan());
  return 0;
}

async function runApply(): Promise<number> {
  const report = await scan();
  if (!flag("json")) await printScan(report);
  const deletable = report.findings.filter((f) => !f.blocked && f.tier !== "red");
  if (deletable.length === 0) {
    await printApply(idleApply());
    if (!flag("json")) say("Không có mục nào đủ điều kiện xóa.");
    return 0;
  }
  if (!flag("yes") && !(await confirmSummary(deletable, report.totals.blocked.count))) {
    await printApply(idleApply());
    if (!flag("json")) say("Đã hủy. Không có gì bị xóa.");
    return 0;
  }
  const result = await apply(report, { tiers: tierChoicesFor(report), assumeYes: flag("yes"), onPrompt: askYellow });
  await printApply(result);
  return result.outcomes.some((o) => o.status === "failed") ? 1 : 0;
}

function tierChoicesFor(report: ScanReport): TierChoice {
  const choices: TierChoice = {};
  for (const finding of report.findings) {
    if (finding.blocked || finding.tier === "red") continue;
    if (finding.tier === "green") choices[finding.ruleId] = "green";
    else if (!(finding.ruleId in choices)) choices[finding.ruleId] = "yellow";
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

async function runUi(): Promise<number> {
  const { startServer } = await import("./ui/server.ts");
  const port = Number(opt("port") ?? 4173);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) {
    say("port không hợp lệ (cần 1024-65535)");
    return 1;
  }
  const server = await startServer({ port, open: !flag("no-open") });
  say(`\n${bold("Dustless")} đang chạy tại ${bold(server.url)}`);
  say(dim("chỉ nghe trên 127.0.0.1 · nhấn Ctrl+C để dừng\n"));
  await new Promise<void>((resolve) => {
    process.once("SIGINT", () => resolve());
    process.once("SIGTERM", () => resolve());
  });
  await server.close();
  return 0;
}

async function runRule(sub: string, rest: string[]): Promise<number> {
  if (sub === "list") {
    const rules = await loadRules();
    if (flag("json")) {
      await writeOut(`${JSON.stringify(rules)}\n`);
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
    await writeOut(`${JSON.stringify(found, null, 2)}\n`);
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
  const hygiene = await inspectSystem();
  const report = {
    platform,
    home: HOME,
    configDir: configDir(),
    rules: (await loadRules()).length,
    total: usage.bytes,
    free: await freeSpace(),
    paths: Object.fromEntries(await Promise.all(KEY_PATHS.map(async (p) => [p, await probe(p)] as const))),
    hygiene,
  };
  if (flag("json")) {
    await writeOut(`${JSON.stringify(report, null, 2)}\n`);
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
  const stale = hygiene.items.filter((item) => item.severity === "warn");
  say(bold(`\n  vệ sinh hệ thống  ${hygiene.startupCount} khởi động · ${hygiene.toolchainCount} toolchain`));
  for (const item of stale.slice(0, 8)) {
    say(`  ${paint("33", "!")} ${dim(`${item.kind}/${item.label}`.padEnd(34))} ${item.detail}`);
  }
  if (stale.length > 8) say(dim(`  … và ${stale.length - 8} mục nữa, xem --json`));
  if (hygiene.items.length === 0) say(dim("  không có mục nào đáng ngờ"));
  return mail.includes("EPERM") ? 1 : 0;
}

async function runNet(): Promise<number> {
  const flags: NetFlags = {
    advanced: flag("advanced"),
    flushDns: flag("flush-dns"),
    resetDns: flag("reset-dns"),
    renewDhcp: flag("renew-dhcp"),
    clearArp: flag("clear-arp"),
    resetMtu: flag("reset-mtu"),
    flushRouting: flag("flush-routing"),
  };
  const report = await net({ ops: selectOps(flags), dryRun: flag("dry-run"), force: flag("force") });
  await printNet(report);
  return report.outcomes.some((o) => o.status === "failed") ? 1 : 0;
}

async function printNet(report: NetReport): Promise<void> {
  if (flag("json")) {
    await writeOut(`${JSON.stringify(report)}\n`);
    return;
  }
  say(bold(`\ndustless net — ${report.platform}`));
  say(`  interface  ${report.iface ?? dim("không rõ")}`);
  say(`  gateway    ${report.gateway ?? dim("không rõ")}`);
  say(`  dns        ${report.dns.length ? report.dns.join(", ") : dim("không rõ")}`);
  if (report.outcomes.length === 0) {
    say(dim("\nkhông có thao tác nào được chọn — `dustless net` (mặc định) chỉ flush DNS cache."));
    say(dim("thao tác nâng cao chạy từng cái một: --reset-dns --renew-dhcp --clear-arp --reset-mtu --flush-routing"));
    return;
  }
  say("");
  for (const o of report.outcomes) {
    const mark =
      o.status === "ran" ? paint("32", "✔") : o.status === "failed" ? paint("31", "✖") : o.status === "refused" ? paint("33", "⛔") : paint("33", "–");
    say(`${mark} ${dim(o.op.padEnd(12))} ${o.detail}`);
    if (o.before !== undefined && o.after !== undefined) say(`  ${dim(`${o.before} → ${o.after}`)}`);
  }
  say("");
}

async function runApps(_rest: string[]): Promise<number> {
  const { resolve } = await import("node:path");
  const home = homedir();
  const uninstallPath = opt("uninstall");
  const confirm = flag("confirm");
  const purge = flag("purge");
  const trashDir = opt("trash-dir");

  if (uninstallPath) {
    const apps = await listApps({ home });
    const target = apps.find((a) => a.path === uninstallPath || resolve(a.path) === resolve(uninstallPath));
    if (!target) {
      if (flag("json")) {
        await writeOut(`${JSON.stringify({ error: "app not found in inventory", path: uninstallPath })}\n`);
      } else {
        say(`✖ ứng dụng không có trong danh sách: ${uninstallPath}`);
      }
      return 1;
    }
    const report = await uninstall({
      home,
      appPath: target.path,
      relatedPaths: target.relatedPaths,
      confirm,
      purge,
      trashDir,
    });
    if (flag("json")) {
      await writeOut(`${JSON.stringify(report)}\n`);
      return report.summary.failed > 0 ? 1 : 0;
    }
    for (const o of report.outcomes) {
      const mark =
        o.status === "trashed"
          ? paint("32", "🗑")
          : o.status === "purged"
            ? paint("31", "🔥")
            : o.status === "skipped"
              ? paint("33", "⊘")
              : paint("31", "✖");
      say(`${mark} ${bytesOf(o.bytes).padStart(9)}  ${o.path}`);
      if (o.detail) say(`  ${dim(o.detail)}`);
    }
    say(
      `\n${paint("32", `🗑 ${report.summary.trashed}`)}  ${paint("31", `🔥 ${report.summary.purged}`)}  ${paint("33", `⊘ ${report.summary.skipped}`)}  ${paint("31", `✖ ${report.summary.failed}`)} · ${bold(`tổng ${bytesOf(report.summary.totalBytes)}`)}`,
    );
    return report.summary.failed > 0 ? 1 : 0;
  }

  const apps = await listApps({ home });
  if (flag("json")) {
    await writeOut(`${JSON.stringify(apps)}\n`);
    return 0;
  }
  if (!apps.length) {
    say(dim("Không tìm thấy ứng dụng .app nào."));
    return 0;
  }
  say(bold(`\n${apps.length} ứng dụng`));
  for (const app of apps) {
    say(`${paint("36", app.name.padEnd(30))} ${bytesOf(app.bytes).padStart(9)}  ${dim(app.bundleId)}  ${app.path}`);
    if (app.relatedPaths.length) {
      say(`  ${dim("← dư:")} ${app.relatedPaths.map((p) => dim(p.replace(home, "~"))).join(", ")}`);
    }
  }
  return 0;
}

async function main(): Promise<number> {
  if (flag("version")) {
    console.log(flag("json") ? JSON.stringify({ version: VERSION }) : VERSION);
    return 0;
  }
  const [command = "help", ...rest] = args;
  if (command === "scan") return await runScan();
  if (command === "apply") return await runApply();
  if (command === "rule") return await runRule(rest[0] ?? "", rest.slice(1));
  if (command === "doctor") return await runDoctor();
  if (command === "ui") return await runUi();
  if (command === "net") return await runNet();
  if (command === "mcp") {
    await serveMcp();
    return 0;
  }
  if (command === "ram") return await runRam();
  if (command === "apps") return await runApps(rest);
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

// `main()` can print hundreds of KB (e.g. `ram --json` lists every process).
// When stdout is a pipe the kernel buffer fills at 64 KiB and the rest waits in
// user space, so letting the process end here truncated the tail to exactly
// 65536 bytes — file redirects looked fine, but MCP clients, agents and the app
// read through pipes and got broken JSON. Drain stdout first.
function flushStdout(): Promise<void> {
  return new Promise((resolve) => process.stdout.write("", () => resolve()));
}

process.on("unhandledRejection", (reason) => {
  console.error(paint("31", String(reason)));
  void flushStdout().finally(() => process.exit(1));
});

main().then(
  async (code) => {
    await flushStdout();
    process.exitCode = code;
  },
  async (err: Error) => {
    console.error(paint("31", `✖ ${err.message}`));
    await flushStdout();
    process.exitCode = 1;
  },
);