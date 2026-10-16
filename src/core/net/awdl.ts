import type { Platform } from "../../types.ts";
import { platform } from "../paths.ts";
import { isRoot, systemRun, type Runner } from "./run.ts";

// AWDL (Apple Wireless Direct Link) is the peer-to-peer radio behind AirDrop,
// Handoff and Universal Clipboard. It timeshares the Wi-Fi chip and, on Apple
// silicon, is a well-documented cause of periodic ping spikes and random
// disconnects. Putting awdl0 down keeps Wi-Fi and internet fully working and
// only costs those Apple continuity features — so it is a toggle, not a
// maintenance op, and it lives beside `net` rather than inside it.
//
// This is the one place in Dustless that escalates with `sudo -n`: the toggle
// is meant to be one click from the menu bar, not a terminal round-trip. It is
// scoped by a single sudoers rule that allows exactly the two `ifconfig`
// commands below and nothing else (see `awdlPrivilege` and docs/NETWORK.md).
export const AWDL_INTERFACE = "awdl0";
export const IFCONFIG = "/sbin/ifconfig";
export const AWDL_PRIVILEGE_PATH = "/etc/sudoers.d/dustless-awdl";

export type AwdlState = "on" | "off" | "absent";

export type AwdlOutcome = {
  status: "ran" | "refused" | "failed" | "not-applicable";
  detail: string;
};

export type AwdlReport = {
  platform: Platform;
  interface: string | null;
  state: AwdlState;
  changed: boolean;
  outcome: AwdlOutcome | null;
};

export type AwdlPrivilege = {
  user: string;
  path: string;
  /** The two commands the rule permits, each absolute and exact. */
  allowed: string[];
  /** The full sudoers.d line, newline-terminated. */
  rule: string;
};

export type AwdlOptions = {
  run?: Runner;
  isRootUser?: () => boolean;
  platform?: Platform;
};

const ROOT_HINT =
  "cần quyền root — cài quy tắc sudo giới hạn trong app Dustless, hoặc chạy lại bằng sudo";

/** Read the live awdl0 state. Never writes, so it is safe to poll. */
export async function readAwdlState(run: Runner, p: Platform): Promise<AwdlState> {
  if (p !== "mac") return "absent";
  const res = await run(IFCONFIG, [AWDL_INTERFACE]);
  // A missing interface (`ifconfig: interface awdl0 does not exist`) and a
  // present-but-down one are both "not on"; the exit status tells them apart.
  if (!res.ok) return /does not exist/i.test(res.err) ? "absent" : "off";
  return /^\s*status:\s*active/m.test(res.out) ? "on" : "off";
}

export async function awdlStatus(opts: AwdlOptions = {}): Promise<AwdlReport> {
  const run = opts.run ?? systemRun;
  const p = opts.platform ?? platform;
  return {
    platform: p,
    interface: p === "mac" ? AWDL_INTERFACE : null,
    state: await readAwdlState(run, p),
    changed: false,
    outcome: null,
  };
}

export async function setAwdl(on: boolean, opts: AwdlOptions = {}): Promise<AwdlReport> {
  const run = opts.run ?? systemRun;
  const root = opts.isRootUser ?? isRoot;
  const p = opts.platform ?? platform;

  if (p !== "mac") {
    return {
      platform: p,
      interface: null,
      state: "absent",
      changed: false,
      outcome: { status: "not-applicable", detail: "AWDL only exists on macOS" },
    };
  }

  const verb = on ? "up" : "down";
  // As root, touch the interface directly. Otherwise escalate through the one
  // sudoers rule; `-n` fails loudly instead of ever blocking on a password
  // prompt the caller cannot answer.
  const res = root()
    ? await run(IFCONFIG, [AWDL_INTERFACE, verb])
    : await run("sudo", ["-n", IFCONFIG, AWDL_INTERFACE, verb]);

  const state = await readAwdlState(run, p);
  if (res.ok) {
    return {
      platform: p,
      interface: AWDL_INTERFACE,
      state,
      changed: true,
      outcome: {
        status: "ran",
        detail: on ? `${AWDL_INTERFACE} up — AirDrop/Handoff available` : `${AWDL_INTERFACE} down — Wi-Fi stays stable`,
      },
    };
  }

  const needsPassword = !root() && /password is required|a terminal is required/i.test(res.err);
  return {
    platform: p,
    interface: AWDL_INTERFACE,
    state,
    changed: false,
    outcome: {
      status: needsPassword ? "refused" : "failed",
      detail: needsPassword ? ROOT_HINT : res.err.trim() || `${IFCONFIG} ${AWDL_INTERFACE} ${verb} failed`,
    },
  };
}

/** The exact sudoers.d content the menu-bar toggle needs, and nothing more. */
export function awdlPrivilege(user: string): AwdlPrivilege {
  const allowed = [`${IFCONFIG} ${AWDL_INTERFACE} down`, `${IFCONFIG} ${AWDL_INTERFACE} up`];
  return {
    user,
    path: AWDL_PRIVILEGE_PATH,
    allowed,
    rule: `${user} ALL=(root) NOPASSWD: ${allowed.join(", ")}\n`,
  };
}

/** A sudoers user/group name must not smuggle extra rules past the writer. */
export function validSudoersUser(user: string): boolean {
  // `ALL` is the sudoers wildcard for every user and `..` is a path traversal
  // token; neither is a real account name, and either would widen the rule.
  return (
    /^[A-Za-z0-9._-]{1,32}$/.test(user) &&
    !user.startsWith("-") &&
    user !== "." &&
    user !== ".." &&
    user.toLowerCase() !== "all"
  );
}
