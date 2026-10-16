import { describe, expect, test } from "bun:test";
import {
  AWDL_INTERFACE,
  AWDL_PRIVILEGE_PATH,
  awdlPrivilege,
  awdlStatus,
  IFCONFIG,
  readAwdlState,
  setAwdl,
  validSudoersUser,
} from "../src/core/net/awdl.ts";
import type { Runner, RunResult } from "../src/core/net/run.ts";

type Call = { cmd: string; args: string[] };

const ACTIVE = "awdl0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tstatus: active\n";
const DOWN = "awdl0: flags=8822<BROADCAST,SMART,SIMPLEX,MULTICAST> mtu 1500\n";

function stub(overrides: Record<string, Partial<RunResult>> = {}) {
  const calls: Call[] = [];
  const run: Runner = async (cmd, args) => {
    calls.push({ cmd, args });
    const preset = overrides[`${cmd} ${args.join(" ")}`];
    return {
      ok: preset?.ok ?? true,
      code: preset?.ok === false ? 1 : preset?.code ?? 0,
      out: preset?.out ?? "",
      err: preset?.err ?? "",
    };
  };
  return { run, calls };
}

const ROOT = () => true;
const USER = () => false;

describe("readAwdlState", () => {
  test("active status reads as on", async () => {
    const { run } = stub({ [`${IFCONFIG} ${AWDL_INTERFACE}`]: { out: ACTIVE } });
    expect(await readAwdlState(run, "mac")).toBe("on");
  });

  test("a present but down interface reads as off", async () => {
    const { run } = stub({ [`${IFCONFIG} ${AWDL_INTERFACE}`]: { out: DOWN } });
    expect(await readAwdlState(run, "mac")).toBe("off");
  });

  test("a missing interface reads as absent, not off", async () => {
    const { run } = stub({
      [`${IFCONFIG} ${AWDL_INTERFACE}`]: { ok: false, err: "ifconfig: interface awdl0 does not exist" },
    });
    expect(await readAwdlState(run, "mac")).toBe("absent");
  });

  test("non-macOS platforms have no AWDL", async () => {
    for (const p of ["linux", "win"] as const) {
      const { run, calls } = stub();
      expect(await readAwdlState(run, p)).toBe("absent");
      expect(calls).toEqual([]);
    }
  });
});

describe("awdlStatus", () => {
  test("reads state and never writes", async () => {
    const { run, calls } = stub({ [`${IFCONFIG} ${AWDL_INTERFACE}`]: { out: ACTIVE } });
    const report = await awdlStatus({ run, platform: "mac" });
    expect(report).toEqual({
      platform: "mac",
      interface: AWDL_INTERFACE,
      state: "on",
      changed: false,
      outcome: null,
    });
    expect(calls).toEqual([{ cmd: IFCONFIG, args: [AWDL_INTERFACE] }]);
  });
});

describe("setAwdl", () => {
  test("as root it touches the interface directly and reports the change", async () => {
    const { run, calls } = stub();
    const report = await setAwdl(false, { run, platform: "mac", isRootUser: ROOT });
    expect(report.changed).toBe(true);
    expect(report.state).toBe("off");
    expect(report.outcome?.status).toBe("ran");
    expect(calls[0]).toEqual({ cmd: IFCONFIG, args: [AWDL_INTERFACE, "down"] });
    expect(calls.some((c) => c.cmd === "sudo")).toBe(false);
  });

  test("turning it on reports on once the interface is active", async () => {
    const { run } = stub({ [`${IFCONFIG} ${AWDL_INTERFACE}`]: { out: ACTIVE } });
    const report = await setAwdl(true, { run, platform: "mac", isRootUser: ROOT });
    expect(report.state).toBe("on");
    expect(report.changed).toBe(true);
    expect(report.outcome?.detail).toContain("AirDrop");
  });

  test("as a normal user it escalates through the one scoped sudo rule", async () => {
    const { run, calls } = stub();
    const report = await setAwdl(false, { run, platform: "mac", isRootUser: USER });
    expect(report.changed).toBe(true);
    expect(calls[0]).toEqual({ cmd: "sudo", args: ["-n", IFCONFIG, AWDL_INTERFACE, "down"] });
  });

  test("a refusal (no sudo rule) is reported, not silently swallowed", async () => {
    const { run, calls } = stub({
      "sudo -n /sbin/ifconfig awdl0 down": { ok: false, err: "sudo: a password is required" },
    });
    const report = await setAwdl(false, { run, platform: "mac", isRootUser: USER });
    expect(report.outcome?.status).toBe("refused");
    expect(report.outcome?.detail).toContain("root");
    expect(report.changed).toBe(false);
    // The failed escalation must not fall back to an unprivileged write.
    expect(calls.some((c) => c.cmd === IFCONFIG && c.args.includes("down"))).toBe(false);
  });

  test("a genuine ifconfig failure is reported as failed", async () => {
    const { run } = stub({ [`${IFCONFIG} ${AWDL_INTERFACE} down`]: { ok: false, err: "operation not permitted" } });
    const report = await setAwdl(false, { run, platform: "mac", isRootUser: ROOT });
    expect(report.outcome?.status).toBe("failed");
    expect(report.outcome?.detail).toBe("operation not permitted");
  });

  test("is not available away from macOS", async () => {
    const { run, calls } = stub();
    const report = await setAwdl(false, { run, platform: "linux", isRootUser: ROOT });
    expect(report.outcome?.status).toBe("not-applicable");
    expect(report.changed).toBe(false);
    expect(calls).toEqual([]);
  });

  test("the interface name is a constant, never interpolated input", async () => {
    const { run, calls } = stub();
    await setAwdl(false, { run, platform: "mac", isRootUser: ROOT });
    for (const call of calls) {
      expect(call.args.every((arg) => !arg.includes(" "))).toBe(true);
      expect(call.cmd).toBe(IFCONFIG);
    }
  });
});

describe("awdlPrivilege", () => {
  test("allows exactly the two ifconfig commands and nothing else", () => {
    const privilege = awdlPrivilege("mac");
    expect(privilege.path).toBe(AWDL_PRIVILEGE_PATH);
    expect(privilege.allowed).toEqual([`${IFCONFIG} ${AWDL_INTERFACE} down`, `${IFCONFIG} ${AWDL_INTERFACE} up`]);
    expect(privilege.rule).toBe(
      "mac ALL=(root) NOPASSWD: /sbin/ifconfig awdl0 down, /sbin/ifconfig awdl0 up\n",
    );
    // NOPASSWD, scoped, and no wildcard that would widen the rule.
    expect(privilege.rule).toContain("NOPASSWD:");
    expect(privilege.rule).not.toContain("*");
  });

  test("the file name has no dot, which sudo silently ignores", () => {
    expect(AWDL_PRIVILEGE_PATH.split("/").pop()).not.toContain(".");
  });
});

describe("validSudoersUser", () => {
  test("accepts ordinary account names", () => {
    for (const user of ["mac", "dung-le", "user_1", "a.b"]) expect(validSudoersUser(user)).toBe(true);
  });

  test("rejects anything that could inject a second rule", () => {
    for (const user of ["", "a b", "a,b", "a\n b", "all: ALL=(root)", "-x", ".", "a\\b"]) {
      expect(validSudoersUser(user)).toBe(false);
    }
  });
});
