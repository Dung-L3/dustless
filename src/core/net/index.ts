import type { Platform } from "../../types.ts";
import { platform } from "../paths.ts";
import { buildSteps, OPS, type NetOpId, type Step } from "./commands.ts";

export type { NetOpId } from "./commands.ts";
import { inspect, type NetInfo } from "./inspect.ts";
import { isRoot, systemRun, type Runner } from "./run.ts";
export { netPrivilege, NET_PRIVILEGE_PATH, type NetPrivilege } from "./privilege.ts";

export type NetOutcome = {
  op: NetOpId;
  status: "ran" | "refused" | "failed" | "skipped" | "not-applicable";
  detail: string;
  before?: string;
  after?: string;
};

export type NetReport = {
  platform: Platform;
  iface: string | null;
  gateway: string | null;
  dns: string[];
  soloRoute: boolean;
  outcomes: NetOutcome[];
};

export type NetOptions = {
  ops?: NetOpId[];
  dryRun?: boolean;
  force?: boolean;
  run?: Runner;
  isRootUser?: () => boolean;
  platform?: Platform;
};

export type NetFlags = {
  advanced: boolean;
  flushDns: boolean;
  resetDns: boolean;
  renewDhcp: boolean;
  clearArp: boolean;
  resetMtu: boolean;
  flushRouting: boolean;
};

const DEFAULT_OPS: NetOpId[] = ["flush-dns"];

const PRIVILEGE_HINT =
  "cần một lần cài quy tắc sudo giới hạn trong app Dustless (bước “ghi nhớ quyền”), hoặc chạy lại bằng sudo";

export function selectOps(flags: NetFlags): NetOpId[] | undefined {
  const named: NetOpId[] = [];
  if (flags.flushDns) named.push("flush-dns");
  if (flags.resetDns) named.push("reset-dns");
  if (flags.renewDhcp) named.push("renew-dhcp");
  if (flags.clearArp) named.push("clear-arp");
  if (flags.resetMtu) named.push("reset-mtu");
  if (flags.flushRouting) named.push("flush-routing");
  if (named.length > 0) return named;
  if (flags.advanced) return [];
  return undefined;
}

export async function net(opts: NetOptions = {}): Promise<NetReport> {
  const run = opts.run ?? systemRun;
  const root = opts.isRootUser ?? isRoot;
  const p = opts.platform ?? platform;
  const info = await inspect(p, run);
  const ops = opts.ops ?? DEFAULT_OPS;
  const outcomes: NetOutcome[] = [];
  for (const id of ops) outcomes.push(await runOp(id, opts, info, run, root, p));
  return {
    platform: p,
    iface: info.iface,
    gateway: info.gateway,
    dns: info.dns,
    soloRoute: info.soloRoute,
    outcomes,
  };
}

async function runOp(
  id: NetOpId,
  opts: NetOptions,
  info: NetInfo,
  run: Runner,
  root: () => boolean,
  p: Platform,
): Promise<NetOutcome> {
  const meta = OPS.find((op) => op.id === id);
  if (!meta) return { op: id, status: "not-applicable", detail: `unknown operation "${id}"` };
  const steps = buildSteps(id, info, p);
  if (steps.length === 0) {
    return { op: id, status: "not-applicable", detail: notApplicableNote(id, p) };
  }
  const before = await beforeValue(id, info, run, p);
  if (meta.targetsInterface && !info.iface) {
    return { op: id, status: "refused", detail: "no active interface found", before };
  }
  if (opts.dryRun) {
    const current = before ? ` (currently ${before})` : "";
    return { op: id, status: "skipped", detail: `would ${meta.label}${current}`, before };
  }
  if (!meta.advanced) {
    return await flushDns(steps, run);
  }
  if (meta.targetsInterface && meta.canInterrupt && info.soloRoute && !opts.force) {
    return {
      op: id,
      status: "refused",
      detail: `${info.iface} is the only route to the network; pass --force to override`,
      before,
    };
  }
  // Root runs the step directly. Otherwise it goes through `sudo -n <path>`,
  // which the scoped sudoers rule can allow and nothing else — `-n` fails
  // loudly instead of blocking on a password prompt the caller cannot answer.
  // There is deliberately no unprivileged fallback: a network change that
  // half-applied is worse than a clean refusal.
  return await execute(id, steps, before, run, !root());
}

async function beforeValue(id: NetOpId, info: NetInfo, run: Runner, p: Platform): Promise<string | undefined> {
  if (id === "reset-dns") return info.dns.length > 0 ? info.dns.join(", ") : "no DNS servers set";
  if (id === "renew-dhcp") return `interface ${info.iface ?? "unknown"}`;
  if (id === "reset-mtu") return await currentMtu(info, run, p);
  return undefined;
}

async function currentMtu(info: NetInfo, run: Runner, p: Platform): Promise<string> {
  if (p !== "mac") return "unknown";
  const res = await run("networksetup", ["-getMTU", info.service]);
  return firstMatch(res.out, /(\d+)/) ?? "unknown";
}

async function flushDns(steps: Step[], run: Runner): Promise<NetOutcome> {
  const results: { step: Step; ok: boolean; err: string }[] = [];
  for (const step of steps) {
    const res = await run(step.cmd, step.args);
    results.push({ step, ok: res.ok, err: res.err.trim() });
  }
  const failed = results.filter((r) => !r.ok);
  if (failed.length === results.length) {
    const first = failed[0];
    return {
      op: "flush-dns",
      status: "failed",
      detail: first ? first.err || `${first.step.cmd} failed` : "flush failed",
    };
  }
  const skipped = failed.map((r) => r.step.cmd).join(", ");
  return {
    op: "flush-dns",
    status: "ran",
    detail: skipped ? `DNS cache flushed (${skipped} skipped: needs root)` : "DNS cache flushed",
  };
}

/**
 * Runs every step of one operation. `escalate` wraps each in `sudo -n`, the
 * same way the AWDL toggle does, so one scoped sudoers rule covers both.
 */
async function execute(
  id: NetOpId,
  steps: Step[],
  before: string | undefined,
  run: Runner,
  escalate: boolean,
): Promise<NetOutcome> {
  let failure = "";
  for (const step of steps) {
    const res = escalate
      ? await run("sudo", ["-n", step.cmd, ...step.args])
      : await run(step.cmd, step.args);
    if (!res.ok && !failure) failure = res.err.trim() || `${step.cmd} failed (exit ${res.code})`;
  }
  if (failure) {
    // A missing sudoers rule is not a broken command, it is a consent the user
    // has not given yet — name the fix instead of showing sudo's own sentence.
    const needsPassword = escalate && /password is required|a terminal is required/i.test(failure);
    return { op: id, status: needsPassword ? "refused" : "failed", detail: needsPassword ? PRIVILEGE_HINT : failure, before };
  }
  return { op: id, status: "ran", detail: ranDetail(id), before, after: afterValue(id) };
}

function ranDetail(id: NetOpId): string {
  switch (id) {
    case "flush-dns":
      return "DNS cache flushed";
    case "reset-dns":
      return "DNS servers reset to DHCP-provided values";
    case "renew-dhcp":
      return "DHCP lease renewed";
    case "clear-arp":
      return "ARP cache cleared; neighbours re-learn automatically";
    case "reset-mtu":
      return "MTU reset to the default (1500)";
    case "flush-routing":
      return "route cache flushed";
  }
}

function afterValue(id: NetOpId): string | undefined {
  if (id === "reset-dns") return "DHCP-provided values";
  if (id === "reset-mtu") return "1500 (default)";
  return undefined;
}

function notApplicableNote(id: NetOpId, p: Platform): string {
  if (id === "flush-routing") {
    if (p === "mac") return "no route cache to flush on macOS; `route flush` would drop every route including the default, so it is refused by design";
    return "no route cache to flush on Windows; `route -f` clears the whole routing table, so it is refused by design";
  }
  return "not available on this platform";
}

function firstMatch(text: string, re: RegExp): string | null {
  const m = re.exec(text);
  return m?.[1] ?? null;
}
