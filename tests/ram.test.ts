import { describe, expect, test } from "bun:test";
import { createRam } from "../src/core/ram/index.ts";
import type { ExecResult, ProcessInfo } from "../src/core/ram/types.ts";

const KIB = 1024;

type FakePsRow = Partial<ProcessInfo> & { pid: number; name: string; mem: number };

function memResponse(total: number, pages: { free: number; active: number; wired: number; compressed: number }, pressure: number): Record<string, ExecResult> {
  return {
    "sysctl -n hw.memsize": { code: 0, out: `${total}\n`, err: "" },
    "vm_stat": {
      code: 0,
      out: [
        "Mach Virtual Memory Statistics: (page size of 16384 bytes)",
        `Pages free: ${pages.free}`,
        `Pages active: ${pages.active}`,
        `Pages wired down: ${pages.wired}`,
        `Pages occupied by compressor: ${pages.compressed}`,
      ].join("\n"),
      err: "",
    },
    "sysctl -n vm.memory_pressure": { code: 0, out: `${pressure}\n`, err: "" },
    "sysctl vm.swapusage": { code: 0, out: "vm.swapusage: total = 2048.00M  used = 512.00M  free = 1536.00M  (encrypted)\n", err: "" },
  };
}

function psResponse(rows: FakePsRow[]): Record<string, ExecResult> {
  const lines = rows.map((row) => {
    const owner = row.root ? "root" : (row.owner ?? "alice");
    const cpu = row.cpu ?? 0;
    const rss = Math.round(row.mem / KIB);
    const ppid = row.ppid ?? 1000;
    return `${row.pid} ${ppid} ${owner} ${cpu.toFixed(1)} ${rss} ${row.name} ${row.command ?? row.name}`;
  });
  return {
    "ps -ax -o pid,ppid,ruser,pcpu,rss,command": {
      code: 0,
      out: ["PID PPID RUSER %CPU RSS COMMAND", ...lines].join("\n"),
      err: "",
    },
  };
}

function fakeExec(responses: Record<string, ExecResult>): (cmd: string, args: string[]) => Promise<ExecResult> {
  return async (cmd, args) => {
    const key = [cmd, ...args].join(" ");
    if (key in responses) return responses[key] as ExecResult;
    return { code: 0, out: "", err: "" };
  };
}

describe("memory", () => {
  test("figures are internally consistent", async () => {
    const ram = createRam({
      exec: fakeExec(memResponse(17179869184, { free: 100000, active: 500000, wired: 200000, compressed: 50000 }, 0)),
    });
    const mem = await ram.getMemoryInfo();
    expect(mem.total).toBe(17179869184);
    expect(mem.used).toBeGreaterThan(0);
    expect(mem.available).toBeGreaterThan(0);
    expect(mem.used + mem.available).toBeLessThanOrEqual(mem.total + 1);
    expect(mem.free).toBeGreaterThanOrEqual(0);
    expect(mem.compressed).toBeGreaterThanOrEqual(0);
    expect(mem.swapTotal).toBeGreaterThan(0);
    expect(mem.swapUsed).toBeGreaterThanOrEqual(0);
    expect(Number.isNaN(mem.total)).toBe(false);
    expect(Number.isNaN(mem.used)).toBe(false);
    expect(Number.isNaN(mem.available)).toBe(false);
  });

  test("pressure is reported, not just free RAM", async () => {
    const ram = createRam({
      exec: fakeExec(memResponse(17179869184, { free: 100, active: 900000, wired: 800000, compressed: 100000 }, 4)),
    });
    const mem = await ram.getMemoryInfo();
    expect(mem.pressure).toBe("critical");
    expect(mem.pressurePercent).toBeGreaterThan(0);
  });

  test("swap bytes stay integers when sysctl reports a fraction", async () => {
    const ram = createRam({
      exec: fakeExec({
        ...memResponse(34359738368, { free: 100000, active: 500000, wired: 200000, compressed: 50000 }, 0),
        "sysctl vm.swapusage": {
          code: 0,
          out: "vm.swapusage: total = 1024.00M  used = 5.12M  free = 1018.88M  (encrypted)\n",
          err: "",
        },
      }),
    });
    const mem = await ram.getMemoryInfo();
    expect(Number.isInteger(mem.swapUsed)).toBe(true);
    expect(Number.isInteger(mem.swapTotal)).toBe(true);
    expect(mem.swapUsed).toBe(Math.round(5.12 * KIB * KIB));
    expect(JSON.parse(JSON.stringify(mem)).swapUsed).toBe(mem.swapUsed);
  });
});

describe("processes", () => {
  test("a process whose app path contains a space keeps its full helper name", async () => {
    const ram = createRam({
      exec: fakeExec(psResponse([
        { pid: 31337, name: "Brave Browser Helper", mem: 400 * KIB * KIB, command: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser Helper --type=renderer" },
      ])),
    });
    const procs = await ram.getProcesses();
    expect(procs[0]?.name).toBe("Brave Browser Helper");
  });

  test("groups processes by executable category", async () => {
    const ram = createRam({
      exec: fakeExec(psResponse([
        { pid: 1234, name: "Google Chrome Helper", mem: 400 * KIB * KIB, command: "/Applications/Google Chrome.app/..." },
        { pid: 5678, name: "Cursor", mem: 800 * KIB * KIB, command: "/Applications/Cursor.app/..." },
        { pid: 9999, name: "kernel_task", mem: 5 * KIB * KIB, command: "kernel_task" },
      ])),
    });
    const procs = await ram.getProcesses();
    expect(procs.find((p) => p.pid === 1234)?.category).toBe("browser");
    expect(procs.find((p) => p.pid === 5678)?.category).toBe("editor");
    expect(procs.find((p) => p.pid === 9999)?.category).toBe("other");
  });
});

describe("kill", () => {
  test("--kill without --confirm signals nothing", async () => {
    const signals: Array<{ pid: number; signal: string }> = [];
    const ram = createRam({
      exec: fakeExec(psResponse([{ pid: 1234, name: "Chrome", mem: 400 * KIB * KIB, command: "/Chrome" }])),
      kill: (pid, signal) => { signals.push({ pid, signal }); },
    });
    const result = await ram.killProcess(1234, { confirm: false });
    expect(result.ok).toBe(false);
    expect(result.reason?.toLowerCase()).toContain("dry-run");
    expect(signals).toHaveLength(0);
  });

  test("refuses PID 1", async () => {
    const signals: Array<{ pid: number; signal: string }> = [];
    const ram = createRam({
      exec: fakeExec(psResponse([{ pid: 1, name: "launchd", mem: 10 * KIB * KIB * 1024, command: "/sbin/launchd" }])),
      kill: (pid, signal) => { signals.push({ pid, signal }); },
    });
    const result = await ram.killProcess(1, { confirm: true });
    expect(result.ok).toBe(false);
    expect(result.reason).toMatch(/PID 1/);
    expect(signals).toHaveLength(0);
  });

  test("refuses root-owned process without --force", async () => {
    const signals: Array<{ pid: number; signal: string }> = [];
    const ram = createRam({
      exec: fakeExec(psResponse([{ pid: 4321, name: "Docker", mem: 500 * KIB * KIB, command: "/Docker", owner: "root", root: true }])),
      kill: (pid, signal) => { signals.push({ pid, signal }); },
    });
    const result = await ram.killProcess(4321, { confirm: true });
    expect(result.ok).toBe(false);
    expect(result.reason).toMatch(/root/);
    expect(signals).toHaveLength(0);
  });

  test("refuses WindowServer", async () => {
    const signals: Array<{ pid: number; signal: string }> = [];
    const ram = createRam({
      exec: fakeExec(psResponse([{ pid: 777, name: "WindowServer", mem: 500 * KIB * KIB, command: "/System/WindowServer" }])),
      kill: (pid, signal) => { signals.push({ pid, signal }); },
    });
    const result = await ram.killProcess(777, { confirm: true });
    expect(result.ok).toBe(false);
    expect(result.reason).toMatch(/WindowServer/);
    expect(signals).toHaveLength(0);
  });

  test("refuses the current Dustless PID", async () => {
    const signals: Array<{ pid: number; signal: string }> = [];
    const ram = createRam({
      exec: fakeExec(psResponse([{ pid: 42, name: "dustless", mem: 500 * KIB * KIB, command: "bun dustless" }])),
      kill: (pid, signal) => { signals.push({ pid, signal }); },
      getOwnPid: () => 42,
      getParentPid: () => 1,
    });
    const result = await ram.killProcess(42, { confirm: true });
    expect(result.ok).toBe(false);
    expect(result.reason).toMatch(/current process|Dustless/);
    expect(signals).toHaveLength(0);
  });

  test("refuses the parent shell", async () => {
    const signals: Array<{ pid: number; signal: string }> = [];
    const ram = createRam({
      exec: fakeExec(psResponse([{ pid: 7, name: "zsh", mem: 500 * KIB * KIB, command: "/bin/zsh" }])),
      kill: (pid, signal) => { signals.push({ pid, signal }); },
      getOwnPid: () => 42,
      getParentPid: () => 7,
    });
    const result = await ram.killProcess(7, { confirm: true });
    expect(result.ok).toBe(false);
    expect(result.reason).toMatch(/parent shell/);
    expect(signals).toHaveLength(0);
  });

  test("SIGKILL requires its own explicit flag", async () => {
    const signals: Array<{ pid: number; signal: string }> = [];
    const ram = createRam({
      exec: fakeExec(psResponse([{ pid: 1234, name: "Chrome", mem: 400 * KIB * KIB, command: "/Chrome" }])),
      kill: (pid, signal) => { signals.push({ pid, signal }); },
    });
    await ram.killProcess(1234, { confirm: true });
    expect(signals).toEqual([{ pid: 1234, signal: "SIGTERM" }]);
    signals.length = 0;
    await ram.killProcess(1234, { confirm: true, sigkill: true });
    expect(signals).toEqual([{ pid: 1234, signal: "SIGKILL" }]);
  });

  test("refuses processes below the usefulness threshold", async () => {
    const signals: Array<{ pid: number; signal: string }> = [];
    const ram = createRam({
      exec: fakeExec(psResponse([{ pid: 1234, name: "Tiny", mem: 10 * 1024 * 1024, command: "/Tiny" }])),
      kill: (pid, signal) => { signals.push({ pid, signal }); },
    });
    const result = await ram.killProcess(1234, { confirm: true });
    expect(result.ok).toBe(false);
    expect(result.reason).toMatch(/threshold/);
    expect(signals).toHaveLength(0);
  });

  test("real kill is never invoked in tests", async () => {
    let called = false;
    const ram = createRam({
      exec: fakeExec(psResponse([{ pid: 1234, name: "Chrome", mem: 400 * KIB * KIB, command: "/Chrome" }])),
      kill: () => { called = true; },
      getOwnPid: () => 42,
      getParentPid: () => 1,
    });
    await ram.killProcess(1234, { confirm: false });
    expect(called).toBe(false);
  });
});
