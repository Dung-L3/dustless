import { lstat, readdir } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve, sep } from "node:path";
import { moveToTrash } from "../apps/index.ts";
import type { UninstallOutcome, UninstallReport } from "../apps/types.ts";

const MiB = 1024 * 1024;
export const DEFAULT_MIN_SIZE = 200 * MiB;
export const DEFAULT_LIMIT = 50;

/**
 * Directories the walk never enters.
 * - `.Trash` is what the user already reclaimed; listing it would offer to
 *   trash the same bytes twice.
 * - `.git` holds repository history, not junk. A pack or a loose object is
 *   owned by the repo, and trashing one corrupts it rather than freeing space.
 *   Everything else in the home directory — Documents, Desktop, caches,
 *   `Library` — is walked on purpose: those are the files hogging the disk.
 */
const SKIP_DIRS = new Set([".git", ".Trash"]);

export type LargeFile = {
  path: string;
  size: number;
  mtime: number;
};

export type FindLargeFilesOptions = {
  /** Directories to walk. Default: the home directory. */
  roots?: string[];
  /** Smallest file worth reporting, in bytes. Default: 200 MiB. */
  minSize?: number;
  /** How many entries to return, largest first. Default: 50. */
  limit?: number;
};

export type DeleteLargeFileOptions = {
  path: string;
  /** The roots the listing was built from; the path must be inside one. */
  roots?: string[];
  confirm: boolean;
  /** Defaults to `~/.Trash`, same as `dustless apps --uninstall`. */
  trashDir?: string;
};

/**
 * Only directories inside the home directory are ever walked. That one rule is
 * what keeps `/System`, `/Library`, `/Applications`, `/private/var` and every
 * other volume and mount out — none of them live under `$HOME` — instead of
 * carrying a deny list that would need one entry per new system directory.
 */
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

/** Unreadable directories and files are skipped silently — a walk of a real
 * home hits TCC-protected folders and racing temp files on every run. */
async function walk(root: string, minSize: number, found: LargeFile[]): Promise<void> {
  const stack = [root];
  while (stack.length) {
    const dir = stack.pop();
    if (dir === undefined) break;
    const entries = await readdir(dir, { withFileTypes: true }).catch(() => null);
    if (!entries) continue;
    const files: string[] = [];
    for (const entry of entries) {
      // A symlink is not the bytes it points at, and following one would walk
      // (and then offer to trash) files the user never sees at that path.
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
  }
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

/**
 * Moves one listed file to the Trash. There is no hard delete: the path has to
 * be a plain file inside a scanned root, and the same `moveToTrash` the app
 * uninstaller uses, so the result is an ordinary `.Trash` entry the user can
 * put back.
 */
export async function deleteLargeFile(opts: DeleteLargeFileOptions): Promise<UninstallReport> {
  const target = resolve(opts.path);
  const roots = scannedRoots(opts.roots);
  const refuse = (detail: string): UninstallReport => ({
    outcomes: [{ path: opts.path, status: "failed", bytes: 0, detail }],
    summary: { trashed: 0, purged: 0, skipped: 0, failed: 1, totalBytes: 0 },
  });

  if (!roots.some((root) => target === root || target.startsWith(root + sep))) {
    return refuse("outside the scanned roots");
  }
  if (!opts.confirm) return refuse("confirm required");
  const meta = await lstat(target).catch(() => null);
  if (!meta) return refuse("does not exist");
  if (meta.isSymbolicLink()) return refuse("refusing symlink");
  if (!meta.isFile()) return refuse("not a regular file");

  const outcome: UninstallOutcome = { path: target, ...(await moveToTrash(target, opts.trashDir ?? join(homedir(), ".Trash"))) };
  const ok = outcome.status === "trashed";
  return {
    outcomes: [outcome],
    summary: { trashed: ok ? 1 : 0, purged: 0, skipped: 0, failed: ok ? 0 : 1, totalBytes: outcome.bytes },
  };
}