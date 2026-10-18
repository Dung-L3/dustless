import { writeOut } from "../core/output.ts";
import { awdlPrivilege, awdlStatus, setAwdl, validSudoersUser, type AwdlReport } from "../core/net/awdl.ts";
import { netPrivilegeSteps } from "../core/net/commands.ts";
import { net, netExitCode, netPrivilege, selectOps, type NetFlags, type NetReport } from "../core/net/index.ts";
import { inspect } from "../core/net/inspect.ts";
import { systemRun } from "../core/net/run.ts";
import { platform } from "../core/paths.ts";
import { bold, dim, fail, flag, paint, say } from "./context.ts";

export async function runNet(): Promise<number> {
  if (flag("print-privilege")) return await printNetPrivilege();
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
  return netExitCode(report);
}

async function printNetPrivilege(): Promise<number> {
  if (platform !== "mac") {
    return await fail("quy tắc sudoers cho net chỉ áp dụng trên macOS");
  }
  const user = process.env["USER"] ?? "";
  if (!validSudoersUser(user)) {
    return await fail(`không dùng được "${user}" cho quy tắc sudoers`);
  }
  try {
    const info = await inspect(platform, systemRun);
    if (!info.iface || !info.service) {
      return await fail(
        `không phân giải được dịch vụ mạng hiện tại (interface: ${info.iface ?? "?"}, service: ${info.service || "?"}) — không in được quy tắc sudo chính xác`,
      );
    }
    const privilege = netPrivilege(user, netPrivilegeSteps(info));
    if (flag("json")) {
      await writeOut(`${JSON.stringify(privilege)}\n`);
      return 0;
    }
    await writeOut(privilege.rule);
    return 0;
  } catch (error) {
    return await fail(error instanceof Error ? error.message : String(error));
  }
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

export async function runAwdl(): Promise<number> {
  if (flag("print-privilege")) {
    const user = process.env["USER"] ?? "";
    if (!validSudoersUser(user)) {
      return await fail(`không dùng được "${user}" cho quy tắc sudoers`);
    }
    const privilege = awdlPrivilege(user);
    if (flag("json")) {
      await writeOut(`${JSON.stringify(privilege)}\n`);
      return 0;
    }
    await writeOut(privilege.rule);
    return 0;
  }
  const on = flag("on");
  const off = flag("off");
  if (on && off) {
    return await fail("chọn một trong hai: --on hoặc --off");
  }
  const report = on || off ? await setAwdl(on) : await awdlStatus();
  await printAwdl(report);
  return report.outcome?.status === "failed" ? 1 : 0;
}

async function printAwdl(report: AwdlReport): Promise<void> {
  if (flag("json")) {
    await writeOut(`${JSON.stringify(report)}\n`);
    return;
  }
  say(bold(`\ndustless awdl — ${report.platform}`));
  say(`  interface  ${report.interface ?? dim("không có")}`);
  const state =
    report.state === "on" ? "BẬT — AirDrop/Handoff chạy được" : report.state === "off" ? dim("TẮT — Wi-Fi ổn định") : dim("không có mặt");
  say(`  AWDL       ${state}`);
  if (report.outcome) {
    const mark =
      report.outcome.status === "ran" ? paint("32", "✔") : report.outcome.status === "refused" ? paint("33", "⛔") : paint("31", "✖");
    say(`  ${mark} ${report.outcome.detail}`);
  } else if (report.state === "on") {
    say(dim("  AWDL đang bật — có thể gây gai ping và rớt Wi-Fi. Tắt bằng: sudo dustless awdl --off"));
  }
  say("");
}
