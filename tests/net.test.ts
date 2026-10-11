import { describe, expect, test } from "bun:test";
import { net, selectOps, type NetOpId } from "../src/core/net/index.ts";
import type { Runner, RunResult } from "../src/core/net/run.ts";
import type { Platform } from "../src/types.ts";

type Call = { cmd: string; args: string[] };
type Presets = Record<Platform, Record<string, string>>;

// Inspection presets mirror what each platform's `inspect()` actually runs, so
// the injected platform produces a self-consistent NetInfo from the stub alone.
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

// The one state-changing write each advanced op issues per platform, derived
// straight from buildSteps. This is what we assert a given op actually issued,
// and what the DNS-flush safety check ensures is never touched on the default path.
const OP_WRITES: Partial<Record<NetOpId, Partial<Record<Platform, Call>>>> = {
  "reset-dns": {
    mac: { cmd: "networksetup", args: ["-setdnsservers", "Wi-Fi", "Empty"] },
    linux: { cmd: "resolvectl", args: ["revert", "en0"] },
    win: { cmd: "netsh", args: ["interface", "ip", "set", "dnsservers", "name=en0", "source=dhcp"] },
  },
  "renew-dhcp": {
    mac: { cmd: "ipconfig", args: ["set", "en0", "DHCP"] },
    linux: { cmd: "dhclient", args: ["-r", "en0"] },
    win: { cmd: "ipconfig", args: ["/renew"] },
  },
  "clear-arp": {
    mac: { cmd: "arp", args: ["-d", "-a"] },
    linux: { cmd: "ip", args: ["-s", "-s", "neigh", "flush", "all"] },
    win: { cmd: "arp", args: ["-d", "*"] },
  },
  "reset-mtu": {
    mac: { cmd: "networksetup", args: ["-setMTU", "Wi-Fi", "1500"] },
    linux: { cmd: "ip", args: ["link", "set", "en0", "mtu", "1500"] },
    win: { cmd: "netsh", args: ["interface", "ipv4", "set", "subinterface", "en0", "mtu=1500", "store=persistent"] },
  },
  "flush-routing": {
    linux: { cmd: "ip", args: ["route", "flush", "cache"] },
  },
};

// The flush is a non-advanced op; the canonical per-platform flush command is
// asserted directly in the default-path tests rather than conflated with writes.
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
  test("refuses a non-root user with a clear message", async () => {
    const { run, calls } = stub("mac");
    const report = await net({ ops: ["reset-dns"], platform: "mac", run, isRootUser: () => false });
    expect(report.outcomes[0]?.status).toBe("refused");
    expect(report.outcomes[0]?.detail).toContain("root");
    expect(advancedWrites(calls)).toEqual([]);
  });

  test("the solo-route guard refuses without --force and allows it", async () => {
    const solo = stub("mac");
    const refused = await net({ ops: ["reset-dns"], platform: "mac", run: solo.run, isRootUser: () => true });
    expect(refused.outcomes[0]?.status).toBe("refused");
    expect(refused.outcomes[0]?.detail).toContain("only route");
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

describe("stub provenance", () => {
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
      "networksetup -setdnsservers Wi-Fi Empty": { ok: false, err: "stub rejected" },
    });
    const report = await net({ ops: ["reset-dns"], platform: "mac", run, isRootUser: () => true, force: true });
    expect(report.outcomes[0]?.status).toBe("failed");
    expect(report.outcomes[0]?.detail).toBe("stub rejected");
  });
});