import { readdir } from "node:fs/promises";
import { homedir } from "node:os";
import { writeOut } from "../core/output.ts";
import { HOME, platform } from "../core/paths.ts";
import { configDir, loadRules } from "../core/rules.ts";
import { diskUsage, freeSpace } from "../core/space.ts";
import { inspectSystem } from "../system/index.ts";
import { KEY_PATHS, VERSION, bold, bytesOf, dim, errorOut, flag, paint, say } from "./context.ts";

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

export async function runDoctor(): Promise<number> {
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
  const mail = report.paths["~/Library/Mail"] ?? "";
  const missingFda = mail.includes("EPERM") || mail.includes("EACCES");
  if (flag("json")) {
    await writeOut(`${JSON.stringify(report, null, 2)}\n`);
    return missingFda ? 1 : 0;
  }
  say(bold(`\ndustless doctor ${VERSION}`));
  for (const [key, value] of Object.entries(report).slice(0, 6)) {
    say(`  ${dim(key.padEnd(10))} ${typeof value === "number" && key !== "rules" ? bytesOf(value) : value}`);
  }
  say(bold("\n  đọc được các path"));
  for (const [path, state] of Object.entries(report.paths)) say(`  ${dim(path.padEnd(26))} ${state}`);
  if (missingFda) {
    errorOut(`✖ thiếu Full Disk Access — cấp trong System Settings › Privacy & Security › Full Disk Access`);
  } else {
    say(paint("32", "✔ không thấy dấu hiệu thiếu Full Disk Access"));
  }
  const stale = hygiene.items.filter((item) => item.severity === "warn");
  say(bold(`\n  vệ sinh hệ thống  ${hygiene.startupCount} khởi động · ${hygiene.toolchainCount} toolchain`));
  for (const item of stale.slice(0, 8)) {
    say(`  ${paint("33", "!")} ${dim(`${item.kind}/${item.label}`.padEnd(34))} ${item.detail}`);
  }
  if (stale.length > 8) say(dim(`  … và ${stale.length - 8} mục nữa, xem --json`));
  if (hygiene.items.length === 0) say(dim("  không có mục nào đáng ngờ"));
  return missingFda ? 1 : 0;
}
