import { spawn } from "node:child_process";
import { lstat, statfs } from "node:fs/promises";
import { HOME } from "./paths.ts";

export type Run = { code: number; out: string; err: string };

export async function freeSpace(path: string = HOME): Promise<number> {
  const fromStatfs = await statfsBytes(path);
  if (fromStatfs !== null) return fromStatfs;
  return await dfBytes(path);
}

export async function diskUsage(path: string): Promise<{ bytes: number; mtime: number; atime: number }> {
  const [fs, meta] = await Promise.all([statfs(path), lstat(path)]);
  return {
    bytes: Number(fs.bsize) * Number(fs.blocks),
    mtime: meta.mtimeMs,
    atime: meta.atimeMs,
  };
}

export function exec(cmd: string, args: string[], cwd?: string): Promise<Run> {
  return new Promise((done) => {
    const child = spawn(cmd, args, { cwd });
    let out = "";
    let err = "";
    child.stdout.on("data", (chunk) => {
      out += chunk;
    });
    child.stderr.on("data", (chunk) => {
      err += chunk;
    });
    child.on("error", (cause: Error) => done({ code: -1, out, err: cause.message }));
    child.on("close", (code) => done({ code: code ?? -1, out, err }));
  });
}

async function statfsBytes(path: string): Promise<number | null> {
  try {
    const fs = await statfs(path);
    if (!(Number(fs.bsize) > 0) || !(Number(fs.bavail) > 0)) return null;
    return Number(fs.bsize) * Number(fs.bavail);
  } catch {
    return null;
  }
}

async function dfBytes(path: string): Promise<number> {
  const run = await exec("df", ["-k", path]);
  const lastLine = run.out.trim().split("\n").pop() ?? "";
  const availableKb = Number(lastLine.trim().split(/\s+/)[3]);
  return Number.isFinite(availableKb) ? availableKb * 1024 : 0;
}