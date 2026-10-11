import { exec as spaceExec } from "../space.ts";
import type { KillOptions, KillResult, MemoryInfo, ProcessCategory, ProcessInfo, RamDeps } from "./types.ts";

export type { ProcessCategory, ProcessInfo, MemoryInfo, RamDeps, KillResult } from "./types.ts";
export const MIN_RECLAIMABLE_BYTES = 50 * 1024 * 1024;

const KIB = 1024;
const DEFAULT_EXEC: NonNullable<RamDeps["exec"]> = async (cmd, args) => {
  const run = await spaceExec(cmd, args);
  return { code: run.code, out: run.out, err: run.err };
};

const DEFAULT_KILL: NonNullable<RamDeps["kill"]> = (pid, signal) => {
  process.kill(pid, signal);
};

export function createRam(deps: RamDeps = {}) {
  const exec = deps.exec ?? DEFAULT_EXEC;
  const kill = deps.kill ?? DEFAULT_KILL;
  const getOwnPid = deps.getOwnPid ?? (() => process.pid);
  const getParentPid = deps.getParentPid ?? (() => process.ppid);

  async function getMemoryInfo(): Promise<MemoryInfo> {
    const [totalOut, vmOut, pressureOut, swapOut] = await Promise.all([
      exec("sysctl", ["-n", "hw.memsize"]),
      exec("vm_stat", []),
      exec("sysctl", ["-n", "vm.memory_pressure"]),
      exec("sysctl", ["vm.swapusage"]),
    ]);
    const total = Number(totalOut.out.trim()) || 0;
    const pageSize = parsePageSize(vmOut.out) || 16384;
    const vm = parseVmStat(vmOut.out, pageSize);
    const compressed = vm.compressed;
    const used = (vm.active + vm.wired + compressed);
    const available = Math.max(0, total - used);
    const free = vm.free;
    const pressureRaw = Number(pressureOut.out.trim()) || 0;
    const pressure = pressureRaw === 0 ? "normal" : pressureRaw === 1 ? "warn" : "critical";
    const pressurePercent = total > 0 ? Math.round(((used / total) * 100)) : 0;
    const swap = parseSwap(swapOut.out);
    return {
      total,
      used,
      available,
      free,
      compressed,
      swapTotal: swap.total,
      swapUsed: swap.used,
      pressure,
      pressurePercent,
    };
  }

  async function getProcesses(): Promise<ProcessInfo[]> {
    const run = await exec("ps", ["-ax", "-o", "pid,ppid,ruser,pcpu,rss,command"]);
    return run.out
      .split("\n")
      .slice(1)
      .map(parsePsLine)
      .filter((p): p is ProcessInfo => p !== null)
      .sort((a, b) => b.mem - a.mem);
  }

  async function killProcess(pid: number, options: KillOptions): Promise<KillResult> {
    const ownPid = getOwnPid();
    const parentPid = getParentPid();
    if (!Number.isFinite(pid) || pid <= 0) return { ok: false, reason: "invalid PID" };
    if (pid === 1) return { ok: false, reason: "refusing to kill PID 1" };
    if (pid === ownPid) return { ok: false, reason: "refusing to kill the current process" };
    if (pid === parentPid) return { ok: false, reason: "refusing to kill the parent shell" };

    const procs = await getProcesses();
    const target = procs.find((p) => p.pid === pid);
    if (!target) return { ok: false, reason: "process not found" };

    const critical = new Set(["kernel_task", "launchd", "WindowServer", "loginwindow"]);
    if (critical.has(target.name)) return { ok: false, reason: `refusing critical process ${target.name}` };
    if (target.root && !options.force) return { ok: false, reason: "refusing root-owned process (use --force to override)" };
    if (target.name.toLowerCase().includes("dustless") || target.command.toLowerCase().includes("dustless")) {
      return { ok: false, reason: "refusing to kill Dustless" };
    }
    if (target.mem < MIN_RECLAIMABLE_BYTES) {
      return { ok: false, reason: `memory ${bytesOf(target.mem)} is below ${bytesOf(MIN_RECLAIMABLE_BYTES)} threshold; killing it would not help` };
    }
    if (!options.confirm) {
      return { ok: false, reason: "dry-run: add --confirm to signal", reclaimable: target.mem };
    }

    const before = await getMemoryInfo();
    const signal = options.sigkill ? "SIGKILL" : "SIGTERM";
    await kill(pid, signal);
    await new Promise((resolve) => setTimeout(resolve, 200));
    const after = await getMemoryInfo();
    const reclaimed = Math.max(0, after.available - before.available);
    return { ok: true, reclaimable: target.mem, reclaimed };
  }

  async function run(argv: string[] = process.argv.slice(2)): Promise<number> {
    const flag = (name: string): boolean => argv.includes(`--${name}`);
    const opt = (name: string): string | undefined => {
      const at = argv.indexOf(`--${name}`);
      return at >= 0 ? argv[at + 1] : undefined;
    };
    const quiet = flag("quiet");
    const json = flag("json");
    const say = (line = ""): void => {
      if (!quiet && !json) console.log(line);
    };

    if (flag("kill")) {
      const pid = Number(opt("kill"));
      if (!Number.isFinite(pid) || pid <= 0) {
        say("error: --kill requires a positive PID");
        return 1;
      }
      const result = await killProcess(pid, { confirm: flag("confirm"), force: flag("force"), sigkill: flag("sigkill") });
      if (json) {
        console.log(JSON.stringify(result));
      } else {
        if (result.ok) {
          say(`Sent ${flag("sigkill") ? "SIGKILL" : "SIGTERM"} to ${pid}`);
          say(`Estimated reclaimable: ${bytesOf(result.reclaimable ?? 0)}`);
          say(`Measured change: ${bytesOf(result.reclaimed ?? 0)}`);
        } else {
          say(`Refused: ${result.reason}`);
          if (result.reclaimable !== undefined) say(`Estimated reclaimable: ${bytesOf(result.reclaimable)}`);
        }
      }
      return result.ok ? 0 : 1;
    }

    const [mem, procs] = await Promise.all([getMemoryInfo(), getProcesses()]);
    if (json) {
      console.log(JSON.stringify({ memory: mem, processes: procs }, null, 2));
      return 0;
    }

    if (flag("list")) {
      const filter = opt("filter")?.toLowerCase();
      const sortKey = (opt("sort") as "name" | "pid" | "cpu" | "mem") ?? "mem";
      let shown = procs;
      if (filter) {
        shown = shown.filter((p) => p.name.toLowerCase().includes(filter) || p.command.toLowerCase().includes(filter));
      }
      shown = sortProcesses(shown, sortKey);
      say("  PID    NAME                 CATEGORY   CPU    MEM       COMMAND");
      for (const p of shown) {
        say(`  ${p.pid.toString().padStart(6)}  ${p.name.padEnd(20)} ${p.category.padEnd(9)} ${p.cpu.toFixed(1).padStart(5)}  ${bytesOf(p.mem).padStart(8)}  ${p.command}`);
      }
      return 0;
    }

    say("Memory:");
    say(`  Total:      ${bytesOf(mem.total)}`);
    say(`  Used:       ${bytesOf(mem.used)}`);
    say(`  Available:  ${bytesOf(mem.available)}`);
    say(`  Free:       ${bytesOf(mem.free)}`);
    say(`  Compressed: ${bytesOf(mem.compressed)}`);
    say(`  Swap:       ${bytesOf(mem.swapUsed)} / ${bytesOf(mem.swapTotal)}`);
    say(`  Pressure:   ${mem.pressurePercent}% (${mem.pressure})`);
    say("");
    say("Top processes by resident memory:");
    for (const p of procs.slice(0, 10)) {
      say(`  ${p.category.padEnd(9)} ${p.pid.toString().padStart(6)}  ${p.name.padEnd(20)} ${bytesOf(p.mem).padStart(8)}  ${p.cpu.toFixed(1).padStart(5)}  ${p.command}`);
    }
    say("");
    say("Free RAM near zero is normal on macOS; memory pressure and available memory matter more.");
    return 0;
  }

  return { getMemoryInfo, getProcesses, killProcess, run };
}

export const defaultRam = createRam();
export const runRam = defaultRam.run.bind(defaultRam);
export const getMemoryInfo = defaultRam.getMemoryInfo.bind(defaultRam);
export const getProcesses = defaultRam.getProcesses.bind(defaultRam);
export const killProcess = defaultRam.killProcess.bind(defaultRam);

function parsePageSize(text: string): number {
  const match = text.match(/page size of (\d+)\s*bytes/);
  return match ? Number(match[1]) : 0;
}

function parseVmStat(text: string, pageSize: number): { free: number; active: number; wired: number; compressed: number } {
  const out = { free: 0, active: 0, wired: 0, compressed: 0 };
  for (const line of text.split("\n")) {
    const m = line.match(/^([\w\s]+?):\s*(\d+)\.?$/);
    if (!m) continue;
    const key = m[1]?.trim();
    if (!key) continue;
    const value = Number(m[2]) * pageSize;
    if (key === "Pages free") out.free = value;
    else if (key === "Pages active") out.active = value;
    else if (key === "Pages wired down") out.wired = value;
    else if (key === "Pages occupied by compressor") out.compressed = value;
  }
  return out;
}

function parseSwap(text: string): { total: number; used: number } {
  const match = text.match(/total\s*=\s*([\d.]+)([KMGT])?\s*.*?used\s*=\s*([\d.]+)([KMGT])?/i);
  if (!match) return { total: 0, used: 0 };
  const totalValue = match[1];
  const totalUnit = match[2];
  const usedValue = match[3];
  const usedUnit = match[4];
  if (!totalValue || !usedValue) return { total: 0, used: 0 };
  return {
    total: parseSize(Number(totalValue), totalUnit),
    used: parseSize(Number(usedValue), usedUnit),
  };
}

function parseSize(value: number, unit: string | undefined): number {
  const multipliers: Record<string, number> = { B: 1, K: KIB, M: KIB * KIB, G: KIB * KIB * KIB, T: KIB * KIB * KIB * KIB };
  return value * (multipliers[unit ?? "B"] ?? 1);
}

function parsePsLine(line: string): ProcessInfo | null {
  const trimmed = line.trim();
  if (!trimmed) return null;
  const parts = trimmed.split(/\s+/);
  if (parts.length < 6) return null;
  const pid = Number(parts[0]);
  const ppid = Number(parts[1]);
  const owner = parts[2] ?? "";
  const cpu = Number(parts[3]);
  const rss = Number(parts[4]);
  const command = parts.slice(5).join(" ");
  const executable = command.split(/\s+/)[0] ?? "";
  const name = executable.split("/").pop() ?? executable;
  if (!Number.isFinite(pid) || pid <= 0) return null;
  return {
    pid,
    ppid,
    name,
    command,
    cpu,
    mem: rss * KIB,
    owner,
    root: owner === "root",
    category: classify(command),
  };
}

function classify(command: string): ProcessCategory {
  const lower = command.toLowerCase();
  if (/(chrome|firefox|safari|brave|arc|edge|opera|vivaldi|orion|chromium)/.test(lower)) return "browser";
  if (/(^|[^a-z])(code|cursor|zed|intellij|idea|pycharm|webstorm|vscode|sublime|atom|vim|neovim|nvim|emacs)/.test(lower)) return "editor";
  if (/(docker|containerd|colima|podman|qemu|hyperkit|virtualbox|vmware|utm)/.test(lower)) return "container";
  if (/(language-server|tsserver|eslint|prettier|clangd|rust-analyzer|gopls|pylsp|jedi|solargraph)/.test(lower)) return "lsp";
  return "other";
}

function sortProcesses(processes: ProcessInfo[], key: "name" | "pid" | "cpu" | "mem"): ProcessInfo[] {
  const copy = [...processes];
  if (key === "name") return copy.sort((a, b) => a.name.localeCompare(b.name));
  if (key === "pid") return copy.sort((a, b) => a.pid - b.pid);
  if (key === "cpu") return copy.sort((a, b) => b.cpu - a.cpu);
  return copy.sort((a, b) => b.mem - a.mem);
}

function bytesOf(n: number): string {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = n;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${unit === 0 ? value : value.toFixed(1)} ${units[unit] ?? "B"}`;
}
