import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { join, resolve } from "node:path";

export const ROOT = resolve(import.meta.dir, "..");
export const DIST = join(ROOT, "dist");
export const APP_SRC = process.env["DUSTLESS_APP_SRC"] ?? join(ROOT, "apps", "dustless-mac");

export type RunOptions = { cwd?: string; env?: NodeJS.ProcessEnv };
export type RunResult = { code: number; stdout: string; stderr: string };

export function run(cmd: string, args: string[], opts: RunOptions = {}): Promise<RunResult> {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { cwd: opts.cwd, env: opts.env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("error", (err) => resolve({ code: -1, stdout, stderr: err.message }));
    child.on("close", (code) => resolve({ code: code ?? -1, stdout, stderr }));
  });
}

export function runInherit(cmd: string, args: string[], opts: RunOptions = {}): Promise<number> {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { cwd: opts.cwd, env: opts.env, stdio: "inherit" });
    child.on("error", (err) => {
      process.stderr.write(`${cmd}: ${err.message}\n`);
      resolve(-1);
    });
    child.on("close", (code) => resolve(code ?? -1));
  });
}

export async function readVersion(): Promise<string> {
  return (JSON.parse(await readFile(join(ROOT, "package.json"), "utf8")) as { version: string }).version;
}

export function fail(message: string): never {
  throw new Error(message);
}
