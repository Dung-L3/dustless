import { lstat, readdir } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve, sep } from "node:path";
import { realGuard, refusalCode } from "../paths.ts";
import { moveToTrash } from "../apps/index.ts";
import type { Reason } from "../../types.ts";
import type { UninstallOutcome, UninstallReport } from "../apps/types.ts";

const MiB = 1024 * 1024;
export const DEFAULT_MIN_SIZE = 200 * MiB;
const DEFAULT_LIMIT = 50;

const SKIP_DIRS = new Set([".git", ".Trash"]);

export type LargeFile = {
  path: string;
  size: number;
  mtime: number;
};

export type FindLargeFilesOptions = {
  roots?: string[];
  minSize?: number;
  limit?: number;
};

export type DeleteLargeFileOptions = {
  path: string;
  roots?: string[];
  confirm: boolean;
  trashDir?: string;
  beforeDelete?: () => void | Promise<void>;
};

function scannedRoots(roots?: string[]): string[] {
  const home = resolve(homedir());
  const list = [...new Set((roots ?? [home]).map((root) => resolve(root)))];
  for (const root of list) {
    if (root !== home && !root.startsWith(home + sep)) {
      throw new Error(`refusing to walk ${root}: only directories inside ${home} are scanned`);
    }
  }
  return list;
}

const WALKERS = 32;

async function walk(root: string, minSize: number, found: LargeFile[]): Promise<void> {
  const stack: string[] = [];

  const visit = async (dir: string): Promise<void> => {
    const entries = await readdir(dir, { withFileTypes: true }).catch(() => null);
    if (!entries) return;
    const files: string[] = [];
    for (const entry of entries) {
      if (entry.isSymbolicLink()) continue;
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        if (!SKIP_DIRS.has(entry.name)) stack.push(full);
      } else if (entry.isFile()) {
        files.push(full);
      }
    }
    const stats = await Promise.all(files.map((file) => lstat(file).catch(() => null)));
    files.forEach((file, at) => {
      const meta = stats[at];
      if (meta && meta.size >= minSize) found.push({ path: file, size: meta.size, mtime: meta.mtimeMs });
    });
  };

  const worker = async (): Promise<void> => {
    while (stack.length) {
      const dir = stack.pop();
      if (dir === undefined) break;
      await visit(dir);
    }
  };

  await visit(root);
  await Promise.all(Array.from({ length: WALKERS }, () => worker()));
}

export async function findLargeFiles(opts: FindLargeFilesOptions = {}): Promise<LargeFile[]> {
  const minSize = opts.minSize ?? DEFAULT_MIN_SIZE;
  const limit = opts.limit ?? DEFAULT_LIMIT;
  const found: LargeFile[] = [];
  for (const root of scannedRoots(opts.roots)) await walk(root, minSize, found);
  return found
    .sort((a, b) => b.size - a.size || a.path.localeCompare(b.path))
    .slice(0, limit);
}

export async function deleteLargeFile(opts: DeleteLargeFileOptions): Promise<UninstallReport> {
  const target = resolve(opts.path);
  const roots = scannedRoots(opts.roots);
  const refuse = (detail: Reason): UninstallReport => ({
    outcomes: [{ path: opts.path, status: "failed", bytes: 0, detail }],
    summary: { trashed: 0, purged: 0, skipped: 0, failed: 1, totalBytes: 0 },
  });

  if (!roots.some((root) => target === root || target.startsWith(root + sep))) {
    return refuse({ code: "outside_roots" });
  }
  const guard = realGuard(target);
  if ("refused" in guard) {
    return refuse({ code: refusalCode(guard.refused) });
  }
  if (!opts.confirm) return refuse({ code: "confirm_required" });
  const meta = await lstat(target).catch(() => null);
  if (!meta) {
    return {
      outcomes: [{ path: opts.path, status: "skipped", bytes: 0, detail: { code: "not_found" } }],
      summary: { trashed: 0, purged: 0, skipped: 1, failed: 0, totalBytes: 0 },
    };
  }
  if (meta.isSymbolicLink()) return refuse({ code: "symlink" });
  if (!meta.isFile()) return refuse({ code: "not_a_regular_file" });

  const outcome: UninstallOutcome = { path: target, ...(await moveToTrash(target, opts.trashDir ?? join(homedir(), ".Trash"), { beforeDelete: opts.beforeDelete })) };
  const ok = outcome.status === "trashed";
  return {
    outcomes: [outcome],
    summary: { trashed: ok ? 1 : 0, purged: 0, skipped: 0, failed: ok ? 0 : 1, totalBytes: outcome.bytes },
  };
}