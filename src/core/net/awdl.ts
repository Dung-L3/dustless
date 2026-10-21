import type { Platform } from "../../types.ts";
import { platform } from "../paths.ts";
import { sudoersPath, sudoersRule } from "./privilege.ts";
import { isRoot, systemRun, type Runner } from "./run.ts";

export { validSudoersUser } from "./privilege.ts";

export const AWDL_INTERFACE = "awdl0";
export const IFCONFIG = "/sbin/ifconfig";
export const IFCONFIG_ALLOWLIST: readonly string[] = [IFCONFIG];
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
  ifconfig?: string;
};

const ROOT_HINT =
  "cần quyền root — cài quy tắc sudo giới hạn trong app Dustless, hoặc chạy lại bằng sudo";

export async function readAwdlState(
  run: Runner,
  p: Platform,
  ifconfig: string = IFCONFIG,
): Promise<AwdlState> {
  if (p !== "mac") return "absent";
  const res = await run(ifconfig, [AWDL_INTERFACE]);
  if (!res.ok) return /does not exist/i.test(res.err) ? "absent" : "off";
  return /^\s*status:\s*active/m.test(res.out) ? "on" : "off";
}

export async function awdlStatus(opts: AwdlOptions = {}): Promise<AwdlReport> {
  const run = opts.run ?? systemRun;
  const p = opts.platform ?? platform;
  const ifconfig = opts.ifconfig ?? IFCONFIG;
  return {
    platform: p,
    interface: p === "mac" ? AWDL_INTERFACE : null,
    state: await readAwdlState(run, p, ifconfig),
    changed: false,
    outcome: null,
  };
}

export async function setAwdl(on: boolean, opts: AwdlOptions = {}): Promise<AwdlReport> {
  const run = opts.run ?? systemRun;
  const root = opts.isRootUser ?? isRoot;
  const p = opts.platform ?? platform;
  const ifconfig = opts.ifconfig ?? IFCONFIG;

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
    ? await run(ifconfig, [AWDL_INTERFACE, verb])
    : await run("sudo", ["-n", ifconfig, AWDL_INTERFACE, verb]);

  const state = await readAwdlState(run, p, ifconfig);
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
      detail: needsConsent ? ROOT_HINT : res.err.trim() || `${ifconfig} ${AWDL_INTERFACE} ${verb} failed`,
    },
  };
}

export function awdlPrivilege(user: string, ifconfig: string = IFCONFIG): AwdlPrivilege {
  const path = sudoersPath(ifconfig, IFCONFIG_ALLOWLIST);
  const allowed = [`${path} ${AWDL_INTERFACE} down`, `${path} ${AWDL_INTERFACE} up`];
  return {
    user,
    path: AWDL_PRIVILEGE_PATH,
    allowed,
    rule: sudoersRule(user, allowed),
  };
}
