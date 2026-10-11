import { describe, expect, test } from "bun:test";
import { net, selectOps, type NetOpId } from "../src/core/net/index.ts";
import type { Runner, RunResult } from "../src/core/net/run.ts";

type Call = { cmd: string; args: string[] };

const MAC: Record<string, string> = {
  "route -n get default": "   route to: default\n    gateway: 192.168.1.1\n  interface: en0\n",
  "scutil --dns": "resolver #1\n  nameserver[0] : 1.1.1.1\n  nameserver[1] : 1.0.0.1\n",
  "networksetup -listallhardwareports": "Hardware Port: Wi-Fi\nDevice: en0\n",
  "netstat -rn -f inet": "default            192.168.1.1        UGScg                 en0\n",
};

function stub(overrides: Record<string, Partial<RunResult>> = {}) {
  const calls: Call[] = [];
  const run: Runner = async (cmd, args) => {
    calls.push({ cmd, args });
    const key = `${cmd} ${args.join(" ")}`;
    const preset: Partial<RunResult> | undefined = overrides[key] ?? (key in MAC ? { out: MAC[key] } : undefined);
    return {
      ok: preset?.ok ?? true,
      code: preset?.ok === false ? 1 : preset?.code ?? 0,
      out: preset?.out ?? "",
      err: preset?.err ?? "",
    };
  };
  return { run, calls };
}

const READ_CMDS = new Set(["route", "scutil", "networksetup", "netstat"]);

const ADVANCED_WRITES: [string, string][] = [
  ["networksetup", "-setdnsservers"],
  ["networksetup", "-setMTU"],
  ["ipconfig", "set"],
  ["ipconfig", "/renew"],
  ["arp", "-d"],
  ["ip", "-s"],
  ["ip", "route"],
  ["ip", "link"],
  ["netsh", "interface"],
  ["resolvectl", "revert"],
  ["dhclient", "-r"],
];

function isAdvancedWrite(c: Call): boolean {
  return ADVANCED_WRITES.some(([cmd, first]) => c.cmd === cmd && c.args[0] === first);
}

describe("default path", () => {
  test("performs only the DNS flush and never an advanced state change", async () => {
    const { run, calls } = stub();
    const report = await net({ run, isRootUser: () => true });
    expect(report.outcomes.map((o) => o.op)).toEqual(["flush-dns"]);
    expect(report.outcomes[0]?.status).toBe("ran");
    expect(calls.filter(isAdvancedWrite)).toEqual([]);
    expect(calls.some((c) => c.cmd === "dscacheutil" && c.args[0] === "-flushcache")).toBe(true);
  });

  test("reports the flush as ran even when only the root half is skipped", async () => {
    const { run, calls } = stub({
      "killall -HUP mDNSResponder": { ok: false, err: "Operation not permitted" },
    });
    const report = await net({ run });
    expect(report.outcomes[0]?.status).toBe("ran");
    expect(report.outcomes[0]?.detail).toContain("needs root");
    expect(calls.filter(isAdvancedWrite)).toEqual([]);
  });

  test("reports failure when every flush command fails", async () => {
    const { run } = stub({
      "dscacheutil -flushcache": { ok: false, err: "boom" },
      "killall -HUP mDNSResponder": { ok: false, err: "boom" },
    });
    const report = await net({ run });
    expect(report.outcomes[0]?.status).toBe("failed");
    expect(report.outcomes[0]?.detail).toBe("boom");
  });
});

describe("advanced selection", () => {
  test("--advanced without a named operation selects nothing", () => {
    const none = selectOps({
      advanced: true,
      flushDns: false,
      resetDns: false,
      renewDhcp: false,
      clearArp: false,
      resetMtu: false,
      flushRouting: false,
    });
    expect(none).toEqual([]);
  });

  test("no named flags and no --advanced selects the default", () => {
    const flags = {
      advanced: false,
      flushDns: false,
      resetDns: false,
      renewDhcp: false,
      clearArp: false,
      resetMtu: false,
      flushRouting: false,
    };
    expect(selectOps(flags)).toBeUndefined();
  });

  test("an empty ops list changes nothing and issues no writes", async () => {
    const { run, calls } = stub();
    const report = await net({ ops: [], run });
    expect(report.outcomes).toEqual([]);
    expect(calls.filter((c) => !READ_CMDS.has(c.cmd))).toEqual([]);
  });

  test("each advanced operation is individually addressable", async () => {
    const cases: { id: NetOpId; write: Call }[] = [
      { id: "reset-dns", write: { cmd: "networksetup", args: ["-setdnsservers", "Wi-Fi", "Empty"] } },
      { id: "renew-dhcp", write: { cmd: "ipconfig", args: ["set", "en0", "DHCP"] } },
      { id: "clear-arp", write: { cmd: "arp", args: ["-d", "-a"] } },
      { id: "reset-mtu", write: { cmd: "networksetup", args: ["-setMTU", "Wi-Fi", "1500"] } },
    ];
    for (const { id, write } of cases) {
      const { run, calls } = stub();
      const report = await net({ ops: [id], run, isRootUser: () => true, force: true });
      expect(report.outcomes[0]?.op).toBe(id);
      expect(report.outcomes[0]?.status).toBe("ran");
      const writes = calls.filter((c) => c.cmd === write.cmd && c.args[0] === write.args[0]);
      expect(writes).toEqual([write]);
      expect(calls.filter(isAdvancedWrite).length).toBe(1);
    }
  });

  test("flush-routing is not-applicable on macOS", async () => {
    const { run, calls } = stub();
    const report = await net({ ops: ["flush-routing"], run, isRootUser: () => true, force: true });
    expect(report.outcomes[0]?.status).toBe("not-applicable");
    expect(report.outcomes[0]?.detail).toContain("route cache");
    expect(calls.filter(isAdvancedWrite)).toEqual([]);
  });
});

describe("safety", () => {
  test("refuses a non-root user with a clear message", async () => {
    const { run, calls } = stub();
    const report = await net({ ops: ["reset-dns"], run, isRootUser: () => false });
    expect(report.outcomes[0]?.status).toBe("refused");
    expect(report.outcomes[0]?.detail).toContain("root");
    expect(calls.filter(isAdvancedWrite)).toEqual([]);
  });

  test("the solo-route guard refuses without --force and allows it", async () => {
    const solo = stub();
    const refused = await net({ ops: ["reset-dns"], run: solo.run, isRootUser: () => true });
    expect(refused.outcomes[0]?.status).toBe("refused");
    expect(refused.outcomes[0]?.detail).toContain("only route");
    expect(solo.calls.filter(isAdvancedWrite)).toEqual([]);

    const forced = stub();
    const ran = await net({ ops: ["reset-dns"], run: forced.run, isRootUser: () => true, force: true });
    expect(ran.outcomes[0]?.status).toBe("ran");
    expect(forced.calls.some((c) => c.cmd === "networksetup" && c.args[0] === "-setdnsservers")).toBe(true);
  });

  test("the guard lets a multi-route host proceed without --force", async () => {
    const { run } = stub({
      "netstat -rn -f inet": { out: "default 192.168.1.1 en0\ndefault 10.0.0.1 en4\n" },
    });
    const report = await net({ ops: ["reset-dns"], run, isRootUser: () => true });
    expect(report.outcomes[0]?.status).toBe("ran");
  });

  test("a destructive command is never built by shell-interpolating user input", async () => {
    const evil = "en0;reboot";
    const { run, calls } = stub({
      "route -n get default": { out: `gateway: 10.0.0.1\ninterface: ${evil}\n` },
    });
    await net({ ops: ["renew-dhcp"], run, isRootUser: () => true, force: true });
    const write = calls.find((c) => c.cmd === "ipconfig" && c.args[0] === "set");
    expect(write).toEqual({ cmd: "ipconfig", args: ["set", evil, "DHCP"] });
    for (const c of calls) {
      expect(Array.isArray(c.args)).toBe(true);
      expect(c.cmd).not.toContain(" ");
    }
  });
});

describe("dry-run", () => {
  test("prints the planned change and mutates nothing", async () => {
    const { run, calls } = stub();
    const report = await net({ ops: ["reset-dns"], dryRun: true, run, isRootUser: () => true });
    expect(report.outcomes[0]?.status).toBe("skipped");
    expect(report.outcomes[0]?.detail).toContain("would reset DNS servers");
    expect(report.outcomes[0]?.before).toBe("1.1.1.1, 1.0.0.1");
    expect(calls.filter(isAdvancedWrite)).toEqual([]);
  });

  test("default dry-run never issues the flush either", async () => {
    const { run, calls } = stub();
    const report = await net({ dryRun: true, run });
    expect(report.outcomes[0]?.status).toBe("skipped");
    expect(calls.filter((c) => c.cmd === "dscacheutil" || c.cmd === "killall")).toEqual([]);
  });
});

describe("stub provenance", () => {
  test("the report is built from the stub, not the real system", async () => {
    const { run } = stub({
      "route -n get default": { out: "gateway: 10.0.0.1\ninterface: en7\n" },
      "scutil --dns": { out: "resolver #1\n  nameserver[0] : 9.9.9.9\n" },
    });
    const report = await net({ run });
    expect(report.iface).toBe("en7");
    expect(report.gateway).toBe("10.0.0.1");
    expect(report.dns).toEqual(["9.9.9.9"]);
  });

  test("a failing write surfaces the stub's own error", async () => {
    const { run } = stub({
      "networksetup -setdnsservers Wi-Fi Empty": { ok: false, err: "stub rejected" },
    });
    const report = await net({ ops: ["reset-dns"], run, isRootUser: () => true, force: true });
    expect(report.outcomes[0]?.status).toBe("failed");
    expect(report.outcomes[0]?.detail).toBe("stub rejected");
  });
});
