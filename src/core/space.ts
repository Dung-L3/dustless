import { spawn } from "node:child_process";
import { lstat, readdir, statfs } from "node:fs/promises";
import { join } from "node:path";
import type { ScanReport, Tier } from "../types.ts";
import { HOME } from "./paths.ts";

export type Run = { code: number; out: string; err: string };

export type MeasuredPath = { path: string; bytes: number };

export type TreeUsage = { bytes: number; mtime: number };

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

export async function treeUsage(path: string): Promise<TreeUsage | null> {
  const root = await lstat(path).catch(() => null);
  if (!root) return null;
  let bytes = root.isFile() ? root.size : 0;
  let mtime = root.mtimeMs;
  if (!root.isDirectory()) return { bytes, mtime };
  const stack = [path];
  while (stack.length) {
    const dir = stack.pop();
    if (dir === undefined) break;
    const entries = await readdir(dir, { withFileTypes: true }).catch(() => null);
    if (!entries) continue;
    for (const entry of entries) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        stack.push(full);
        continue;
      }
      if (!entry.isFile()) continue;
      const meta = await lstat(full).catch(() => null);
      if (!meta) continue;
      bytes += meta.size;
      if (meta.mtimeMs > mtime) mtime = meta.mtimeMs;
    }
  }
  return { bytes, mtime };
}

function comparable(path: string): string {
  return path.replace(/[\\/]+/g, "/").replace(/\/$/, "");
}

export function isNested(child: string, parent: string): boolean {
  const inner = comparable(child);
  const outer = comparable(parent);
  return inner === outer || inner.startsWith(outer + "/");
}

export function accountedBytes(entries: MeasuredPath[]): number {
  const parents: string[] = [];
  let total = 0;
  for (const entry of [...entries].sort((a, b) => a.path.length - b.path.length)) {
    if (parents.some((parent) => isNested(entry.path, parent))) continue;
    parents.push(entry.path);
    total += entry.bytes;
  }
  return total;
}

export function adjustScanAccounting(report: ScanReport): ScanReport {
  const countable = report.findings.filter(
    (finding) => !finding.blocked && (finding.tier === "green" || finding.tier === "yellow"),
  );
  const claimed: string[] = [];
  const counted = new Set<string>();
  for (const finding of [...countable].sort((a, b) => a.path.length - b.path.length)) {
    if (claimed.some((parent) => isNested(finding.path, parent))) continue;
    claimed.push(finding.path);
    counted.add(finding.path);
  }
  const totals = { ...report.totals };
  for (const tier of ["green", "yellow"] as Tier[]) {
    const bucket = totals[tier];
    totals[tier] = {
      count: bucket.count,
      bytes: report.findings
        .filter((finding) => finding.tier === tier && !finding.blocked && counted.has(finding.path))
        .reduce((sum, finding) => sum + finding.bytes, 0),
    };
  }
  return { ...report, totals, reclaimable: totals.green.bytes + totals.yellow.bytes };
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