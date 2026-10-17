import { lstat, mkdir, readFile, readdir, rename, rm, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join, relative, resolve, sep } from "node:path";
import type { AppInfo, ListAppsOptions, UninstallOptions, UninstallOutcome, UninstallReport } from "./types.ts";

const DEFAULT_APP_DIRS = ["/Applications", "~/Applications"];

const RELATIVE_LEFTOVER_PATHS = [
  "Library/Application Support/{id}",
  "Library/Caches/{id}",
  "Library/Preferences/{id}.plist",
  "Library/Logs/{id}",
  "Library/Saved Application State/{id}.savedState",
  "Library/Containers/{id}",
  "Library/Group Containers/{id}",
  "Library/WebKit/{id}",
  "Library/HTTPStorages/{id}",
  "Library/Application Scripts/{id}",
  "Library/LaunchAgents/{id}.plist",
  "Library/Cookies/{id}.binarycookies",
];

const DENY_PATHS = [
  "/",
  "/System",
  "/usr",
  "/bin",
  "/sbin",
  "/Library",
  "/Applications",
];

function expandHome(path: string, home: string): string {
  return path.replace(/^~(?=$|[/\\])/, home);
}

function isUnder(path: string, parent: string): boolean {
  const resolvedPath = resolve(path);
  const resolvedParent = resolve(parent);
  return resolvedPath === resolvedParent || resolvedPath.startsWith(resolvedParent + sep);
}

async function exists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}

async function dirSize(path: string): Promise<number> {
  // A plain file is its own size; readdir() on one throws and reports 0.
  const root = await lstat(path).catch(() => null);
  if (root?.isFile()) return root.size;
  let total = 0;
  const stack = [resolve(path)];
  while (stack.length) {
    const current = stack.pop();
    if (current === undefined) continue;
    try {
      const entries = await readdir(current, { withFileTypes: true });
      for (const entry of entries) {
        const full = join(current, entry.name);
        if (entry.isDirectory()) {
          stack.push(full);
        } else {
          total += (await lstat(full)).size;
        }
      }
    } catch {
      // ignore unreadable
    }
  }
  return total;
}

function parseInfoPlist(xml: string): { bundleId?: string; name?: string; displayName?: string } {
  const result: { bundleId?: string; name?: string; displayName?: string } = {};
  // Apple writes `<key>X</key>` and `<string>Y</string>` on separate lines, but
  // generated plists often put them on one line, so match across whitespace.
  for (const match of xml.matchAll(/<key>\s*([^<]+?)\s*<\/key>\s*<string>([^<]*)<\/string>/g)) {
    const key = match[1];
    const value = match[2];
    if (key === "CFBundleIdentifier") result.bundleId = value;
    else if (key === "CFBundleName") result.name = value;
    else if (key === "CFBundleDisplayName") result.displayName = value;
  }
  return result;
}

async function readBundleInfo(appPath: string): Promise<{ bundleId: string; name: string } | null> {
  const plistPath = join(appPath, "Contents", "Info.plist");
  try {
    const xml = await readFile(plistPath, "utf8");
    const parsed = parseInfoPlist(xml);
    if (!parsed.bundleId) return null;
    const name = parsed.displayName ?? parsed.name ?? parsed.bundleId;
    return { bundleId: parsed.bundleId, name };
  } catch {
    return null;
  }
}

/**
 * A bundle id is a reverse-DNS identifier, never a path. `join()` collapses
 * `..`, so a crafted `CFBundleIdentifier` of `../../../victim` turned every
 * leftover template into a path outside HOME — and `--purge` made that a
 * permanent `rm -rf` of whatever it pointed at. A separator or a `..` is not a
 * bundle id at all; refuse to build paths from one.
 */
function isSafeBundleId(bundleId: string): boolean {
  return bundleId.length > 0 && !bundleId.includes("/") && !bundleId.includes("\\") && !bundleId.includes("..");
}

function deriveRelatedPaths(home: string, bundleId: string): string[] {
  if (!isSafeBundleId(bundleId)) return [];
  const out: string[] = [];
  for (const template of RELATIVE_LEFTOVER_PATHS) {
    const path = expandHome(join(home, template.replace(/{id}/g, bundleId)), home);
    out.push(path);
  }
  return out;
}

function isSystemApp(appPath: string): boolean {
  const resolved = resolve(appPath);
  return resolved.startsWith("/System/Applications" + sep) || resolved === "/System/Applications";
}

function isAllowedAppDir(appPath: string, appDirs: string[]): boolean {
  const resolved = resolve(appPath);
  for (const dir of appDirs) {
    const expanded = expandHome(dir, homedir());
    if (isUnder(resolved, expanded)) {
      const rel = relative(expanded, resolved);
      return !rel.includes(sep); // directly under, not nested
    }
  }
  return false;
}

function isDenied(path: string, home: string): boolean {
  const resolved = resolve(path);
  const resolvedHome = resolve(home);

  // Check if this is an app bundle directly under allowed app directories
  const isAllowedAppBundle = (p: string) => {
    const appDirs = ["/Applications", join(homedir(), "Applications")];
    for (const dir of appDirs) {
      const expanded = expandHome(dir, homedir());
      if (isUnder(p, expanded)) {
        const rel = relative(expanded, p);
        if (!rel.includes(sep) && rel.endsWith(".app")) {
          return true;
        }
      }
    }
    return false;
  };

  if (isAllowedAppBundle(resolved)) {
    return false;
  }

  for (const deny of DENY_PATHS) {
    if (isUnder(resolved, deny)) return true;
  }

  const homeDeny = [
    join(resolvedHome, "Library"),
    join(resolvedHome, "Library", "Application Support"),
    join(resolvedHome, "Library", "Caches"),
    join(resolvedHome, "Library", "Preferences"),
    join(resolvedHome, "Library", "Containers"),
    join(resolvedHome, "Library", "Group Containers"),
    join(resolvedHome, "Library", "Logs"),
  ];

  for (const deny of homeDeny) {
    if (isUnder(resolved, deny)) return true;
  }

  if (!isUnder(resolved, resolvedHome) && !isUnder(resolved, "/Applications") && !isUnder(resolved, join(homedir(), "Applications"))) {
    return true;
  }

  return false;
}

export async function listApps(opts: ListAppsOptions): Promise<AppInfo[]> {
  const home = opts.home ?? homedir();
  const appDirs = (opts.appDirs ?? DEFAULT_APP_DIRS).map((d) => expandHome(d, home));
  const results: AppInfo[] = [];

  for (const appDir of appDirs) {
    let entries: string[];
    try {
      entries = await readdir(appDir, { withFileTypes: true })
        .then((list) => list.filter((e) => e.isDirectory() && e.name.endsWith(".app")).map((e) => e.name));
    } catch {
      continue;
    }

    for (const name of entries) {
      const appPath = join(appDir, name);
      const info = await readBundleInfo(appPath);
      if (!info) continue;

      const bytes = await dirSize(appPath);
      const allRelated = deriveRelatedPaths(home, info.bundleId);
      const existingRelated = [];
      for (const p of allRelated) {
        if (await exists(p)) existingRelated.push(p);
      }

      results.push({
        bundleId: info.bundleId,
        name: info.name,
        path: appPath,
        bytes,
        relatedPaths: existingRelated,
      });
    }
  }

  return results.sort((a, b) => a.name.localeCompare(b.name));
}

/** Shared with `largefiles`: both surfaces move to the Trash the same way. */
export async function moveToTrash(src: string, trashDir: string): Promise<{ status: "trashed" | "failed"; bytes: number; detail: string }> {
  const bytes = await dirSize(src);
  const name = src.split(sep).filter(Boolean).pop() ?? "unknown";
  await mkdir(trashDir, { recursive: true });
  let dest = join(trashDir, name);
  let suffix = 1;
  while (await exists(dest)) {
    dest = join(trashDir, `${name}.${suffix}`);
    suffix++;
  }
  try {
    await rename(src, dest);
    return { status: "trashed", bytes, detail: `moved to ${dest}` };
  } catch (err) {
    return { status: "failed", bytes, detail: String(err) };
  }
}

async function purgePath(src: string): Promise<{ status: "purged" | "failed"; bytes: number; detail: string }> {
  const bytes = await dirSize(src);
  try {
    await rm(src, { recursive: true, force: true });
    return { status: "purged", bytes, detail: "permanently deleted" };
  } catch (err) {
    return { status: "failed", bytes, detail: String(err) };
  }
}

export async function uninstall(opts: UninstallOptions): Promise<UninstallReport> {
  const { home, appPath, relatedPaths, confirm, purge = false, trashDir } = opts;

  if (!confirm) {
    const failedOutcome = (p: string) => ({ path: p, status: "failed" as const, bytes: 0, detail: "confirm required" });
    return {
      outcomes: [
        failedOutcome(appPath),
        ...relatedPaths.map(failedOutcome),
      ],
      summary: { trashed: 0, purged: 0, skipped: 0, failed: 1 + relatedPaths.length, totalBytes: 0 },
    };
  }

  const resolvedAppPath = resolve(appPath);
  const appDirs = DEFAULT_APP_DIRS.map((d) => expandHome(d, home));

  if (!resolvedAppPath.endsWith(".app" + sep) && !resolvedAppPath.endsWith(".app")) {
    return {
      outcomes: [{ path: appPath, status: "failed", bytes: 0, detail: "not a .app bundle" }],
      summary: { trashed: 0, purged: 0, skipped: 0, failed: 1, totalBytes: 0 },
    };
  }

  if (isSystemApp(resolvedAppPath)) {
    return {
      outcomes: [{ path: appPath, status: "failed", bytes: 0, detail: "system app refused" }],
      summary: { trashed: 0, purged: 0, skipped: 0, failed: 1, totalBytes: 0 },
    };
  }

  if (!isAllowedAppDir(resolvedAppPath, appDirs)) {
    return {
      outcomes: [{ path: appPath, status: "failed", bytes: 0, detail: "app not in allowed app directories" }],
      summary: { trashed: 0, purged: 0, skipped: 0, failed: 1, totalBytes: 0 },
    };
  }

  if (isDenied(resolvedAppPath, home)) {
    return {
      outcomes: [{ path: appPath, status: "failed", bytes: 0, detail: "denied path" }],
      summary: { trashed: 0, purged: 0, skipped: 0, failed: 1, totalBytes: 0 },
    };
  }

  // Read bundle ID to validate relatedPaths
  const bundleInfo = await readBundleInfo(resolvedAppPath);
  if (!bundleInfo) {
    return {
      outcomes: [{ path: appPath, status: "failed", bytes: 0, detail: "could not read bundle ID" }],
      summary: { trashed: 0, purged: 0, skipped: 0, failed: 1, totalBytes: 0 },
    };
  }
  // A bundle id that is not a bundle id cannot be expanded into leftovers, and
  // the whole point of refusing it is that we do not know where it would point.
  // Refuse the uninstall rather than remove the bundle and leave the user
  // guessing which of its directories was left behind.
  if (!isSafeBundleId(bundleInfo.bundleId)) {
    return {
      outcomes: [
        { path: appPath, status: "failed", bytes: 0, detail: `bundle id "${bundleInfo.bundleId}" is not a valid identifier` },
      ],
      summary: { trashed: 0, purged: 0, skipped: 0, failed: 1, totalBytes: 0 },
    };
  }

  const expectedRelatedPaths = new Set(deriveRelatedPaths(home, bundleInfo.bundleId).map((p) => resolve(p)));

  const resolvedRelatedPaths = relatedPaths.map((p) => resolve(p));

  // Validate that each relatedPath is a legitimate leftover for this bundle ID.
  // Two independent properties, both required: it resolves strictly inside HOME,
  // and it is exactly one of this bundle id's own template expansions. Either
  // one alone would be enough to stop the `..` escape — the HOME check catches a
  // bundle id that climbs out, the template check catches anything else.
  for (const p of resolvedRelatedPaths) {
    if (!isUnder(p, home) || resolve(p) === resolve(home)) {
      return {
        outcomes: [{ path: p, status: "failed", bytes: 0, detail: "leftover path escapes HOME" }],
        summary: { trashed: 0, purged: 0, skipped: 0, failed: 1, totalBytes: 0 },
      };
    }
    if (!expectedRelatedPaths.has(p)) {
      return {
        outcomes: [{ path: p, status: "failed", bytes: 0, detail: "not a valid leftover path for this app" }],
        summary: { trashed: 0, purged: 0, skipped: 0, failed: 1, totalBytes: 0 },
      };
    }
  }

  const allPaths = [resolvedAppPath, ...resolvedRelatedPaths];
  const trash = trashDir ? expandHome(trashDir, home) : join(home, ".Trash");
  const outcomes: UninstallOutcome[] = [];

  for (const p of allPaths) {
    if (!(await exists(p))) {
      outcomes.push({ path: p, status: "skipped", bytes: 0, detail: "does not exist" });
      continue;
    }

    if (purge) {
      const result = await purgePath(p);
      outcomes.push({ path: p, ...result });
    } else {
      const result = await moveToTrash(p, trash);
      outcomes.push({ path: p, ...result });
    }
  }

  const summary = outcomes.reduce(
    (acc, o) => {
      acc[o.status]++;
      acc.totalBytes += o.bytes;
      return acc;
    },
    { trashed: 0, purged: 0, skipped: 0, failed: 0, totalBytes: 0 } as UninstallReport["summary"],
  );

  return { outcomes, summary };
}