import { stat } from "node:fs/promises";
import { join, resolve, sep } from "node:path";
import type { Reason } from "../../types.ts";
import type { UninstallOutcome, UninstallRelatedOptions, UninstallReport } from "./types.ts";
import {
  deriveRelatedPaths,
  expandHome,
  isAllowedAppDir,
  isDenied,
  isSafeBundleId,
  isSystemApp,
  moveToTrash,
  purgePath,
  scopedAppDirs,
} from "./index.ts";

async function exists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}

function isUnder(path: string, parent: string): boolean {
  const resolvedPath = resolve(path);
  const resolvedParent = resolve(parent);
  return resolvedPath === resolvedParent || resolvedPath.startsWith(resolvedParent + sep);
}

export async function uninstallRelated(opts: UninstallRelatedOptions): Promise<UninstallReport> {
  const { home, bundleId, appPath, relatedPaths, confirm, purge = false, trashDir } = opts;
  const fail = (path: string, code: Reason["code"], params?: Record<string, string>): UninstallReport => ({
    outcomes: [{ path, status: "failed", bytes: 0, detail: { code, ...(params ? { params } : {}) } }],
    summary: { trashed: 0, purged: 0, skipped: 0, failed: 1, totalBytes: 0 },
  });

  if (!confirm) return fail(appPath, "confirm_required");
  if (!isSafeBundleId(bundleId)) return fail(appPath, "bad_bundle_id", { id: bundleId });
  if (bundleId.startsWith("com.apple.")) return fail(appPath, "system_app");

  const resolvedAppPath = resolve(appPath);
  if (!resolvedAppPath.endsWith(".app" + sep) && !resolvedAppPath.endsWith(".app")) {
    return fail(appPath, "not_an_app");
  }
  if (isSystemApp(resolvedAppPath)) return fail(appPath, "system_app");

  const appDirs = scopedAppDirs(home, opts.appDirs);
  if (!isAllowedAppDir(resolvedAppPath, appDirs, home)) return fail(appPath, "not_allowed_dir");
  if (isDenied(resolvedAppPath, home)) return fail(appPath, "denied_path");
  if (await exists(resolvedAppPath)) return fail(appPath, "target_changed");

  const expectedRelatedPaths = new Set(deriveRelatedPaths(home, bundleId).map((p) => resolve(p)));
  const resolvedRelatedPaths = relatedPaths.map((p) => resolve(p));
  for (const p of resolvedRelatedPaths) {
    if (!isUnder(p, home) || p === resolve(home)) return fail(p, "leftover_escapes_home");
    if (!expectedRelatedPaths.has(p)) return fail(p, "not_a_leftover");
  }

  const trash = trashDir ? expandHome(trashDir, home) : join(home, ".Trash");
  const outcomes: UninstallOutcome[] = [];
  for (const p of resolvedRelatedPaths) {
    if (!(await exists(p))) {
      outcomes.push({ path: p, status: "skipped", bytes: 0, detail: { code: "not_found" } });
      continue;
    }
    const result = purge
      ? await purgePath(p, { beforeDelete: opts.beforeDelete })
      : await moveToTrash(p, trash, { beforeDelete: opts.beforeDelete });
    outcomes.push({ path: p, ...result });
  }

  const summary = outcomes.reduce(
    (acc, o) => {
      acc[o.status]++;
      if (o.status === "trashed" || o.status === "purged") acc.totalBytes += o.bytes;
      return acc;
    },
    { trashed: 0, purged: 0, skipped: 0, failed: 0, totalBytes: 0 } as UninstallReport["summary"],
  );
  return { outcomes, summary };
}

