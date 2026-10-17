import type { Platform } from "../../types.ts";
import { platform } from "../paths.ts";
import { isRoot, systemRun, type Runner } from "./run.ts";

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
  allowed: string[];
  rule: string;
};

export type AwdlOptions = {
  run?: Runner;
  isRootUser?: () => boolean;
  platform?: Platform;
};

const ROOT_HINT =
  "cần quyền root — cài quy tắc sudo giới hạn trong app Dustless, hoặc chạy lại bằng sudo";

export async function readAwdlState(run: Runner, p: Platform): Promise<AwdlState> {
  if (p !== "mac") return "absent";
  const res = await run(IFCONFIG, [AWDL_INTERFACE]);
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

  const needsConsent = !root() && /password is required|a terminal is required|not allowed to execute/i.test(res.err);
  return {
    platform: p,
    interface: AWDL_INTERFACE,
    state,
    changed: false,
    outcome: {
      status: needsConsent ? "refused" : "failed",
      detail: needsConsent ? ROOT_HINT : res.err.trim() || `${IFCONFIG} ${AWDL_INTERFACE} ${verb} failed`,
    },
  };
}

export function awdlPrivilege(user: string): AwdlPrivilege {
  const allowed = [`${IFCONFIG} ${AWDL_INTERFACE} down`, `${IFCONFIG} ${AWDL_INTERFACE} up`];
  return {
    user,
    path: AWDL_PRIVILEGE_PATH,
    allowed,
    rule: `${user} ALL=(root) NOPASSWD: ${allowed.join(", ")}\n`,
  };
}

export function validSudoersUser(user: string): boolean {
  return (
    /^[A-Za-z0-9._-]{1,32}$/.test(user) &&
    !user.startsWith("-") &&
    user !== "." &&
    user !== ".." &&
    user.toLowerCase() !== "all"
  );
}