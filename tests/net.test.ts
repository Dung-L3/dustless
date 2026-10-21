import { describe, expect, test } from "bun:test";
import { MAC_COMMANDS, netPrivilegeSteps } from "../src/core/net/commands.ts";
import { inspect } from "../src/core/net/inspect.ts";
import { net, netExitCode, netPrivilege, NET_PRIVILEGE_PATH, selectOps, type NetOpId } from "../src/core/net/index.ts";
import type { Runner, RunResult } from "../src/core/net/run.ts";
import type { Platform } from "../src/types.ts";

type Call = { cmd: string; args: string[] };
type Presets = Record<Platform, Record<string, string>>;

const PRESETS: Presets = {
  mac: {
    "route -n get default": "   route to: default\n    gateway: 192.168.1.1\n  interface: en0\n",
    "scutil --dns": "resolver #1\n  nameserver[0] : 1.1.1.1\n  nameserver[1] : 1.0.0.1\n",
    "networksetup -listallhardwareports": "Hardware Port: Wi-Fi\nDevice: en0\n",
    "netstat -rn -f inet": "default            192.168.1.1        UGScg                 en0\n",
  },
  linux: {
    "ip route show default": "default via 192.168.1.1 dev en0\n",
    "cat /etc/resolv.conf": "nameserver 1.1.1.1\n",
  },
  win: {
    "route print 0.0.0.0": "0.0.0.0 0.0.0.0 192.168.1.1 en0\n",
    "ipconfig /all": "DNS Servers . . . . . . . . . . . : 1.1.1.1\n",
  },
};

function stub(platform: Platform, overrides: Record<string, Partial<RunResult>> = {}) {
  const calls: Call[] = [];
  const run: Runner = async (cmd, args) => {
    calls.push({ cmd, args });
    const key = `${cmd} ${args.join(" ")}`;
    const preset: Partial<RunResult> | undefined =
      overrides[key] ?? (key in PRESETS[platform] ? { out: PRESETS[platform][key] } : undefined);
    return {
      ok: preset?.ok ?? true,
      code: preset?.ok === false ? 1 : preset?.code ?? 0,
      out: preset?.out ?? "",
      err: preset?.err ?? "",
    };
  };
  return { run, calls };
}

const READ_CMDS: Record<Platform, Set<string>> = {
  mac: new Set(["route", "scutil", "networksetup", "netstat"]),
  linux: new Set(["ip", "cat"]),
  win: new Set(["route", "ipconfig"]),
};

const OP_WRITES: Partial<Record<NetOpId, Partial<Record<Platform, Call>>>> = {
  "reset-dns": {
    mac: { cmd: MAC_COMMANDS.networksetup, args: ["-setdnsservers", "Wi-Fi", "Empty"] },
    linux: { cmd: "resolvectl", args: ["revert", "en0"] },
    win: { cmd: "netsh", args: ["interface", "ip", "set", "dnsservers", "name=en0", "source=dhcp"] },
  },
  "renew-dhcp": {
    mac: { cmd: MAC_COMMANDS.ipconfig, args: ["set", "en0", "DHCP"] },
    linux: { cmd: "dhclient", args: ["-r", "en0"] },
    win: { cmd: "ipconfig", args: ["/renew"] },
  },
  "clear-arp": {
    mac: { cmd: MAC_COMMANDS.arp, args: ["-d", "-a"] },
    linux: { cmd: "ip", args: ["-s", "-s", "neigh", "flush", "all"] },
    win: { cmd: "arp", args: ["-d", "*"] },
  },
  "reset-mtu": {
    mac: { cmd: MAC_COMMANDS.networksetup, args: ["-setMTU", "Wi-Fi", "1500"] },
    linux: { cmd: "ip", args: ["link", "set", "en0", "mtu", "1500"] },
    win: { cmd: "netsh", args: ["interface", "ipv4", "set", "subinterface", "en0", "mtu=1500", "store=persistent"] },
  },
  "flush-routing": {
    linux: { cmd: "ip", args: ["route", "flush", "cache"] },
  },
};

const FLUSH: Record<Platform, Call> = {
  mac: { cmd: "dscacheutil", args: ["-flushcache"] },
  linux: { cmd: "resolvectl", args: ["flush-caches"] },
  win: { cmd: "ipconfig", args: ["/flushdns"] },
};

const ALL_ADVANCED = new Set<string>(
  Object.values(OP_WRITES).flatMap((byPlat) => Object.values(byPlat).map((c) => JSON.stringify(c)))
);

function advancedWrites(calls: Call[]): Call[] {
  return calls.filter((c) => ALL_ADVANCED.has(JSON.stringify(c)));
}

const NOT_APPLICABLE: Partial<Record<NetOpId, Platform[]>> = {
  "reset-dns": [],
  "renew-dhcp": [],
  "clear-arp": [],
  "reset-mtu": [],
  "flush-routing": ["mac", "win"],
};

describe("default path", () => {
  test("performs only the DNS flush and never an advanced state change", async () => {
    const { run, calls } = stub("mac");
    const report = await net({ platform: "mac", run, isRootUser: () => true });
    expect(report.outcomes.map((o) => o.op)).toEqual(["flush-dns"]);
    expect(report.outcomes[0]?.status).toBe("ran");
    expect(advancedWrites(calls)).toEqual([]);
    expect(calls).toContainEqual(FLUSH.mac);
  });

  test("the DNS-flush default path never issues an advanced write on any platform", async () => {
    for (const p of ["mac", "linux", "win"] as const) {
      const { run, calls } = stub(p);
      const report = await net({ platform: p, run, isRootUser: () => true });
      expect(report.outcomes.map((o) => o.op)).toEqual(["flush-dns"]);
      expect(report.outcomes[0]?.status).toBe("ran");
      expect(calls).toContainEqual(FLUSH[p]);
      expect(advancedWrites(calls)).toEqual([]);
    }
  });

  test("reports the flush as ran even when only the root half is skipped", async () => {
    const { run, calls } = stub("mac", {
      "killall -HUP mDNSResponder": { ok: false, err: "Operation not permitted" },
    });
    const report = await net({ platform: "mac", run });
    expect(report.outcomes[0]?.status).toBe("ran");
    expect(report.outcomes[0]?.detail).toContain("needs root");
    expect(advancedWrites(calls)).toEqual([]);
  });

  test("reports failure when every flush command fails", async () => {
    const { run } = stub("mac", {
      "dscacheutil -flushcache": { ok: false, err: "boom" },
      "killall -HUP mDNSResponder": { ok: false, err: "boom" },
    });
    const report = await net({ platform: "mac", run });
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
    for (const p of ["mac", "linux", "win"] as const) {
      const { run, calls } = stub(p);
      const report = await net({ ops: [], platform: p, run });
      expect(report.outcomes).toEqual([]);
      expect(calls.every((c) => READ_CMDS[p].has(c.cmd))).toBe(true);
      expect(advancedWrites(calls)).toEqual([]);
    }
  });

  test("each advanced operation is individually addressable on every platform", async () => {
    const platforms: Platform[] = ["mac", "linux", "win"];
    for (const p of platforms) {
      for (const id of Object.keys(OP_WRITES) as NetOpId[]) {
        const { run, calls } = stub(p);
        const report = await net({ ops: [id], platform: p, run, isRootUser: () => true, force: true });
        expect(report.outcomes[0]?.op).toBe(id);
        if ((NOT_APPLICABLE[id] ?? []).includes(p)) {
          expect(report.outcomes[0]?.status).toBe("not-applicable");
          continue;
        }
        expect(report.outcomes[0]?.status).toBe("ran");
        const write = OP_WRITES[id]![p]!;
        expect(calls).toContainEqual(write);
        for (const other of Object.keys(OP_WRITES) as NetOpId[]) {
          const otherWrite = OP_WRITES[other]?.[p];
          if (other === id || !otherWrite) continue;
          expect(calls).not.toContainEqual(otherWrite);
        }
      }
    }
  });

  test("flush-routing is not-applicable on macOS and Windows, applicable on Linux", async () => {
    for (const p of ["mac", "win"] as const) {
      const { run, calls } = stub(p);
      const report = await net({ ops: ["flush-routing"], platform: p, run, isRootUser: () => true, force: true });
      expect(report.outcomes[0]?.status).toBe("not-applicable");
      expect(report.outcomes[0]?.detail).toContain("route cache");
      expect(advancedWrites(calls)).toEqual([]);
    }
    const linux = stub("linux");
    const report = await net({
      ops: ["flush-routing"],
      platform: "linux",
      run: linux.run,
      isRootUser: () => true,
      force: true,
    });
    expect(report.outcomes[0]?.status).toBe("ran");
    expect(linux.calls).toContainEqual(OP_WRITES["flush-routing"]!.linux!);
  });
});

describe("safety", () => {
  test("a non-root user escalates through sudo -n, never a bare write", async () => {
    const { run, calls } = stub("mac");
    const report = await net({ ops: ["reset-dns"], platform: "mac", run, isRootUser: () => false, force: true });
    expect(report.outcomes[0]?.status).toBe("ran");
    expect(calls.filter((c) => c.cmd === "sudo")).toEqual([
      { cmd: "sudo", args: ["-n", MAC_COMMANDS.networksetup, "-setdnsservers", "Wi-Fi", "Empty"] },
    ]);
    expect(calls.filter((c) => c.cmd === MAC_COMMANDS.networksetup)).toEqual([]);
  });

  test("a refused sudo is reported as refused and never retried unprivileged", async () => {
    const { run, calls } = stub("mac", {
      [`sudo -n ${MAC_COMMANDS.networksetup} -setdnsservers Wi-Fi Empty`]: {
        ok: false,
        err: "sudo: a password is required",
      },
    });
    const report = await net({ ops: ["reset-dns"], platform: "mac", run, isRootUser: () => false, force: true });
    const outcome = report.outcomes[0];
    expect(outcome?.status).toBe("refused");
    expect(outcome?.detail).not.toContain("password is required");
    expect(outcome?.detail).toContain("sudo");
    expect(calls.filter((c) => c.cmd !== "sudo")).toEqual(
      calls.filter((c) => READ_CMDS.mac.has(c.cmd)),
    );
  });

  test("a genuine sudo failure is reported as failed, not as a missing permission", async () => {
    const { run } = stub("mac", {
      [`sudo -n ${MAC_COMMANDS.networksetup} -setdnsservers Wi-Fi Empty`]: { ok: false, err: "boom" },
    });
    const report = await net({ ops: ["reset-dns"], platform: "mac", run, isRootUser: () => false, force: true });
    expect(report.outcomes[0]?.status).toBe("failed");
    expect(report.outcomes[0]?.detail).toBe("boom");
  });

  test("a stale rule — 'not allowed to execute' — is a refusal, not a failure", async () => {
    const { run, calls } = stub("mac", {
      [`sudo -n ${MAC_COMMANDS.networksetup} -setdnsservers Wi-Fi Empty`]: {
        ok: false,
        err: "sudo: sorry, user mac is not allowed to execute '/usr/sbin/networksetup -setdnsservers Wi-Fi Empty' as root on host",
      },
    });
    const report = await net({ ops: ["reset-dns"], platform: "mac", run, isRootUser: () => false, force: true });
    const outcome = report.outcomes[0];
    expect(outcome?.status).toBe("refused");
    expect(outcome?.detail).toContain("sudo");
    expect(outcome?.detail).not.toContain("not allowed to execute");
    expect(calls.filter((c) => c.cmd === "sudo")).toHaveLength(1);
  });

  test("every advanced op classifies a stale sudoers rule the same way", async () => {
    const base = stub("mac");
    const denying: Runner = async (cmd, args) =>
      cmd === "sudo"
        ? { ok: false, code: 1, out: "", err: `sudo: sorry, user mac is not allowed to execute '${args.join(" ")}' as root` }
        : base.run(cmd, args);
    for (const id of ["reset-dns", "renew-dhcp", "clear-arp", "reset-mtu"] as const) {
      const report = await net({ ops: [id], platform: "mac", run: denying, isRootUser: () => false, force: true });
      expect({ id, status: report.outcomes[0]?.status }).toEqual({ id, status: "refused" });
    }
  });

  test("the solo-route guard refuses before any escalation is attempted", async () => {
    const solo = stub("mac");
    const refused = await net({ ops: ["reset-dns"], platform: "mac", run: solo.run, isRootUser: () => false });
    expect(refused.outcomes[0]?.status).toBe("refused");
    expect(refused.outcomes[0]?.detail).toContain("only route");
    expect(solo.calls.filter((c) => c.cmd === "sudo")).toEqual([]);
    expect(advancedWrites(solo.calls)).toEqual([]);

    const forced = stub("mac");
    const ran = await net({ ops: ["reset-dns"], platform: "mac", run: forced.run, isRootUser: () => true, force: true });
    expect(ran.outcomes[0]?.status).toBe("ran");
    expect(forced.calls).toContainEqual(OP_WRITES["reset-dns"]!.mac!);
  });

  test("the guard lets a multi-route host proceed without --force", async () => {
    const { run } = stub("mac", {
      "netstat -rn -f inet": { out: "default 192.168.1.1 en0\ndefault 10.0.0.1 en4\n" },
    });
    const report = await net({ ops: ["reset-dns"], platform: "mac", run, isRootUser: () => true });
    expect(report.outcomes[0]?.status).toBe("ran");
  });

  test("a destructive command is never built by shell-interpolating user input", async () => {
    const evil = "en0;reboot";
    const { run, calls } = stub("mac", {
      "route -n get default": { out: `gateway: 10.0.0.1\ninterface: ${evil}\n` },
    });
    await net({ ops: ["renew-dhcp"], platform: "mac", run, isRootUser: () => true, force: true });
    const write = calls.find((c) => c.cmd === MAC_COMMANDS.ipconfig && c.args[0] === "set");
    expect(write).toEqual({ cmd: MAC_COMMANDS.ipconfig, args: ["set", evil, "DHCP"] });
    for (const c of calls) {
      expect(Array.isArray(c.args)).toBe(true);
      expect(c.cmd).not.toContain(" ");
    }
  });
});

describe("dry-run", () => {
  test("prints the planned change and mutates nothing", async () => {
    const { run, calls } = stub("mac");
    const report = await net({ ops: ["reset-dns"], platform: "mac", dryRun: true, run, isRootUser: () => true });
    expect(report.outcomes[0]?.status).toBe("skipped");
    expect(report.outcomes[0]?.detail).toContain("would reset DNS servers");
    expect(report.outcomes[0]?.before).toBe("1.1.1.1, 1.0.0.1");
    expect(advancedWrites(calls)).toEqual([]);
  });

  test("default dry-run never issues the flush either", async () => {
    const { run, calls } = stub("mac");
    const report = await net({ platform: "mac", dryRun: true, run });
    expect(report.outcomes[0]?.status).toBe("skipped");
    expect(calls.filter((c) => c.cmd === "dscacheutil" || c.cmd === "killall")).toEqual([]);
  });
});

describe("resolving the network service", () => {
  const ORDER = "An asterisk (*) denotes that a network service is disabled.\n"
    + "(1) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)\n\n"
    + "(2) Thunderbolt Bridge\n(Hardware Port: Thunderbolt Bridge, Device: bridge0)\n\n"
    + "(3) USB 10/100/1000 LAN (*)\n(Hardware Port: USB 10/100/1000 LAN, Device: en7)\n";

  test("falls back to -listnetworkserviceorder for a device the hardware list omits", async () => {
    const { run } = stub("mac", {
      "route -n get default": { out: "gateway: 192.168.1.1\ninterface: en7\n" },
      "networksetup -listallhardwareports": { out: "Hardware Port: Wi-Fi\nDevice: en0\n" },
      "networksetup -listnetworkserviceorder": { out: ORDER },
    });
    const info = await inspect("mac", run);
    expect(info.iface).toBe("en7");
    expect(info.service).toBe("USB 10/100/1000 LAN");
    const privilege = netPrivilege("mac", netPrivilegeSteps({ ...MAC_INFO, iface: info.iface, service: info.service }));
    expect(privilege.allowed[0]).toBe(`${MAC_COMMANDS.networksetup} -setdnsservers "USB 10/100/1000 LAN" Empty`);
  });

  test("a disabled service still resolves, without the trailing asterisk", async () => {
    const { run } = stub("mac", {
      "route -n get default": { out: "gateway: 192.168.1.1\ninterface: en7\n" },
      "networksetup -listallhardwareports": { out: "" },
      "networksetup -listnetworkserviceorder": { out: ORDER },
    });
    expect((await inspect("mac", run)).service).toBe("USB 10/100/1000 LAN");
  });

  test("a device in neither list yields no service, so no rule can be built", async () => {
    const { run, calls } = stub("mac", {
      "route -n get default": { out: "gateway: 192.168.1.1\ninterface: en9\n" },
      "networksetup -listallhardwareports": { out: "Hardware Port: Wi-Fi\nDevice: en0\n" },
      "networksetup -listnetworkserviceorder": { out: ORDER },
    });
    const info = await inspect("mac", run);
    expect(info.service).toBe("");
    expect(() => netPrivilege("mac", netPrivilegeSteps(info))).toThrow();
    expect(calls.some((c) => c.args.includes("-listnetworkserviceorder"))).toBe(true);
  });

  test("the hardware-port list is preferred, so no second lookup is needed", async () => {
    const { run, calls } = stub("mac", {
      "networksetup -listallhardwareports": { out: "Hardware Port: My Wi-Fi\nDevice: en0\n" },
      "networksetup -listnetworkserviceorder": { out: ORDER },
    });
    expect((await inspect("mac", run)).service).toBe("My Wi-Fi");
    expect(calls.filter((c) => c.args.includes("-listnetworkserviceorder"))).toEqual([]);
  });
});

describe("exit status", () => {
  const report = (...statuses: ("ran" | "refused" | "failed" | "skipped" | "not-applicable")[]) =>
    ({ outcomes: statuses.map((status) => ({ op: "reset-dns" as const, status, detail: "" })) });

  test("every outcome refused is a non-zero exit", () => {
    expect(netExitCode(report("refused", "refused"))).toBe(1);
  });

  test("a failure is a non-zero exit", () => {
    expect(netExitCode(report("ran", "failed"))).toBe(1);
  });

  test("ran, skipped and not-applicable are a clean exit", () => {
    expect(netExitCode(report("ran", "skipped", "not-applicable"))).toBe(0);
  });

  test("a run with no outcomes at all did nothing and says so cleanly", () => {
    expect(netExitCode(report())).toBe(0);
  });
});

describe("stub provenance", () => {
  test("a nameserver repeated across resolvers is listed once", async () => {
    const { run } = stub("mac", {
      "scutil --dns": {
        out: "resolver #1\n  nameserver[0] : 1.1.1.1\n  nameserver[1] : 1.0.0.1\nresolver #2\n  nameserver[0] : 1.1.1.1\n",
      },
    });
    const report = await net({ ops: [], platform: "mac", run });
    expect(report.dns).toEqual(["1.1.1.1", "1.0.0.1"]);
  });

  test("the report is built from the stub, not the real system", async () => {
    const { run } = stub("mac", {
      "route -n get default": { out: "gateway: 10.0.0.1\ninterface: en7\n" },
      "scutil --dns": { out: "resolver #1\n  nameserver[0] : 9.9.9.9\n" },
    });
    const report = await net({ platform: "mac", run });
    expect(report.iface).toBe("en7");
    expect(report.gateway).toBe("10.0.0.1");
    expect(report.dns).toEqual(["9.9.9.9"]);
  });

  test("a failing write surfaces the stub's own error", async () => {
    const { run } = stub("mac", {
      [`${MAC_COMMANDS.networksetup} -setdnsservers Wi-Fi Empty`]: { ok: false, err: "stub rejected" },
    });
    const report = await net({ ops: ["reset-dns"], platform: "mac", run, isRootUser: () => true, force: true });
    expect(report.outcomes[0]?.status).toBe("failed");
    expect(report.outcomes[0]?.detail).toBe("stub rejected");
  });
});

const MAC_INFO = { iface: "en0", gateway: "192.168.1.1", dns: [], service: "Wi-Fi", soloRoute: true };

describe("netPrivilege", () => {
  test("allows exactly the four advanced commands and nothing else", () => {
    const privilege = netPrivilege("mac", netPrivilegeSteps(MAC_INFO));
    expect(privilege.path).toBe(NET_PRIVILEGE_PATH);
    expect(privilege.path).toBe("/etc/sudoers.d/dustless-net");
    expect(privilege.allowed).toEqual([
      `${MAC_COMMANDS.networksetup} -setdnsservers Wi-Fi Empty`,
      `${MAC_COMMANDS.ipconfig} set en0 DHCP`,
      `${MAC_COMMANDS.arp} -d -a`,
      `${MAC_COMMANDS.networksetup} -setMTU Wi-Fi 1500`,
    ]);
    expect(privilege.rule).toBe(
      "mac ALL=(root) NOPASSWD: /usr/sbin/networksetup -setdnsservers Wi-Fi Empty,"
        + " /usr/sbin/ipconfig set en0 DHCP,"
        + " /usr/sbin/arp -d -a,"
        + " /usr/sbin/networksetup -setMTU Wi-Fi 1500\n",
    );
    expect(privilege.rule).toContain("NOPASSWD:");
    expect(privilege.rule).not.toContain("*");
    for (const allowed of privilege.allowed) expect(allowed.startsWith("/")).toBe(true);
    expect(NET_PRIVILEGE_PATH.split("/").pop()).not.toContain(".");
  });

  test("a service name with spaces is quoted, so the rule still matches one argument", () => {
    const info = { ...MAC_INFO, service: "USB 10/100/1000 LAN" };
    const privilege = netPrivilege("mac", netPrivilegeSteps(info));
    expect(privilege.allowed[0]).toBe(`${MAC_COMMANDS.networksetup} -setdnsservers "USB 10/100/1000 LAN" Empty`);
    expect(privilege.allowed[3]).toBe(`${MAC_COMMANDS.networksetup} -setMTU "USB 10/100/1000 LAN" 1500`);
    expect(privilege.allowed[1]).toBe(`${MAC_COMMANDS.ipconfig} set en0 DHCP`);
  });

  test("the rule's quoted service matches the argv the engine actually passes", async () => {
    const service = "USB 10/100/1000 LAN";
    const allowed = netPrivilege("mac", netPrivilegeSteps({ ...MAC_INFO, service })).allowed[0]!;
    const [quoted] = allowed.slice(allowed.indexOf('"')).match(/"([^"]*)"/)!;
    const { run, calls } = stub("mac", {
      "route -n get default": { out: "gateway: 192.168.1.1\ninterface: en0\n" },
      "networksetup -listallhardwareports": { out: "Hardware Port: USB 10/100/1000 LAN\nDevice: en0\n" },
    });
    const report = await net({ ops: ["reset-dns"], platform: "mac", run, isRootUser: () => false, force: true });
    expect(report.outcomes[0]?.status).toBe("ran");
    const call = calls.find((c) => c.cmd === "sudo")!;
    expect(call.args[call.args.indexOf(service)]).toBe(quoted.slice(1, -1));
  });

  test("an absent interface or service refuses to produce a rule", () => {
    for (const info of [{ ...MAC_INFO, iface: null }, { ...MAC_INFO, service: "" }]) {
      expect(() => netPrivilege("mac", netPrivilegeSteps(info))).toThrow();
    }
  });

  test("a service name that could end the argument is refused", () => {
    for (const service of ['Wi"Fi', "Wi-Fi # x", "Wi-Fi\nALL=(root) ALL", ""]) {
      expect(() => netPrivilege("mac", netPrivilegeSteps({ ...MAC_INFO, service }))).toThrow();
    }
  });

  test("a service name holding a sudoers wildcard is refused", () => {
    for (const service of ["Wi*Fi", "Wi?Fi", "Wi-Fi[0-9]", "Wi\\Fi"]) {
      expect(() => netPrivilege("mac", netPrivilegeSteps({ ...MAC_INFO, service }))).toThrow();
    }
    expect(netPrivilege("mac", netPrivilegeSteps(MAC_INFO)).rule).not.toMatch(/[*?[\]\\]/);
  });

  test("a service name holding a shell metacharacter or a command separator is refused", () => {
    for (const service of [
      "Wi-Fi;rm",
      "Wi-Fi|cat",
      "Wi-Fi&",
      "Wi-Fi$HOME",
      "Wi-Fi`id`",
      "Wi-Fi>out",
      "Wi-Fi<input",
      "Wi-Fi(1)",
      "Wi-Fi{1}",
      "Wi-Fi!",
      "Wi-Fi'x'",
      "Wi-Fi,rm",
    ]) {
      expect(() => netPrivilege("mac", netPrivilegeSteps({ ...MAC_INFO, service }))).toThrow();
    }
  });

  test("an account name that could inject a second rule is refused", () => {
    for (const user of ["", "ALL", "a b", "a,b", "mac ALL=(root) NOPASSWD: /bin/sh"]) {
      expect(() => netPrivilege(user, netPrivilegeSteps(MAC_INFO))).toThrow();
    }
  });
});