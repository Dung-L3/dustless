export type ProcessCategory = "browser" | "editor" | "container" | "lsp" | "other";

export type ProcessInfo = {
  pid: number;
  ppid: number;
  name: string;
  command: string;
  cpu: number;
  mem: number;
  owner: string;
  root: boolean;
  category: ProcessCategory;
};

export type MemoryInfo = {
  total: number;
  used: number;
  available: number;
  free: number;
  compressed: number;
  swapTotal: number;
  swapUsed: number;
  pressure: "normal" | "warn" | "critical";
  pressurePercent: number;
};

export type ExecResult = { code: number; out: string; err: string };

export type RamDeps = {
  exec?: (cmd: string, args: string[]) => Promise<ExecResult>;
  kill?: (pid: number, signal: "SIGTERM" | "SIGKILL") => Promise<void> | void;
  getOwnPid?: () => number;
  getParentPid?: () => number | undefined;
};

export type KillOptions = {
  confirm: boolean;
  force?: boolean;
  sigkill?: boolean;
};

export type KillResult = {
  ok: boolean;
  reason?: string;
  reclaimable?: number;
  reclaimed?: number;
};
