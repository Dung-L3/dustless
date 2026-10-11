import { execFile } from "node:child_process";
import { promisify } from "node:util";

export type RunResult = { ok: boolean; code: number; out: string; err: string };

export type Runner = (cmd: string, args: string[]) => Promise<RunResult>;

const execFileAsync = promisify(execFile);

export const systemRun: Runner = async (cmd, args) => {
  try {
    const { stdout, stderr } = await execFileAsync(cmd, args, { timeout: 10_000, windowsHide: true });
    return { ok: true, code: 0, out: String(stdout), err: String(stderr) };
  } catch (error) {
    const e = error as { code?: unknown; stdout?: unknown; stderr?: unknown };
    return {
      ok: false,
      code: typeof e.code === "number" ? e.code : -1,
      out: String(e.stdout ?? ""),
      err: String(e.stderr ?? ""),
    };
  }
};

export function isRoot(): boolean {
  return typeof process.getuid === "function" ? process.getuid() === 0 : true;
}
