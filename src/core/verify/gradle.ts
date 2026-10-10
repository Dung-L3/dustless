import { readdir, readFile } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { HOME, expand } from "../paths.ts";
import type { VerifyResult } from "./index.ts";

const VENDORED_DIRS = new Set([
  "build",
  "SourcePackages",
  ".dartServer",
  "node_modules",
  ".gradle",
  ".pub-cache",
  "DerivedData",
  "Pods",
  "ephemeral",
]);

const CANDIDATE_FILES = new Set([
  "gradle-wrapper.properties",
  "gradle.properties",
  "build.gradle",
  "build.gradle.kts",
]);

const DISTRIBUTION_URL = /gradle-([0-9]+(?:\.[0-9]+)*(?:-[A-Za-z0-9.]+)?)-(?:bin|all)\.zip/i;

const MAX_ENTRIES = 200_000;
const MAX_DEPTH = 12;
const HOME_DEPTH = 2;
const MAX_LISTED = 5;

export const DEFAULT_SEARCH_ROOTS = [
  "~/Innotech",
  "~/Personal",
  "~/Developer",
  "~/Projects",
  "~/repos",
].map(expand);

type Project = { wrapper?: string; override?: string };

export async function gradleVersionUnused(
  cacheVersion: string,
  roots: string[] = [...DEFAULT_SEARCH_ROOTS, HOME],
): Promise<VerifyResult> {
  const budget = { left: MAX_ENTRIES };
  const candidates: string[] = [];
  for (const root of roots) {
    const absolute = resolve(expand(root));
    if (isVendored(absolute)) continue;
    candidates.push(...(await findCandidates(absolute, root === HOME ? HOME_DEPTH : MAX_DEPTH, budget)));
  }

  const projects = new Map<string, Project>();
  for (const file of candidates) {
    if (isVendored(file)) continue;
    const version = await distributionVersion(file);
    if (!version) continue;
    const root = projectRootFor(file);
    const project = projects.get(root) ?? {};
    if (basename(file) === "gradle-wrapper.properties") project.wrapper = version;
    else project.override = version;
    projects.set(root, project);
  }

  const users = [...projects]
    .filter(([, project]) => (project.override ?? project.wrapper) === cacheVersion)
    .map(([root]) => root)
    .sort();

  if (users.length > 0) {
    const shown = users.slice(0, MAX_LISTED).join(", ");
    const rest = users.length > MAX_LISTED ? ` (+${users.length - MAX_LISTED} more)` : "";
    return { ok: false, note: `project ${shown}${rest} uses Gradle ${cacheVersion}` };
  }

  return {
    ok: true,
    note: `no project references Gradle ${cacheVersion} (scanned ${projects.size} projects)`,
  };
}

async function findCandidates(
  root: string,
  maxDepth: number,
  budget: { left: number },
): Promise<string[]> {
  const found: string[] = [];
  const pending = [{ dir: root, depth: 0 }];
  while (pending.length > 0) {
    const current = pending.pop();
    if (!current) break;
    if (current.depth > maxDepth || budget.left <= 0) continue;
    let entries;
    try {
      entries = await readdir(current.dir, { withFileTypes: true });
    } catch {
      continue;
    }
    budget.left -= entries.length;
    for (const entry of entries) {
      const full = join(current.dir, entry.name);
      if (entry.isDirectory()) {
        if (entry.name.startsWith(".") || VENDORED_DIRS.has(entry.name)) continue;
        pending.push({ dir: full, depth: current.depth + 1 });
      } else if (entry.isFile() && CANDIDATE_FILES.has(entry.name)) {
        found.push(full);
      }
    }
  }
  return found;
}

function isVendored(file: string): boolean {
  return file.split(/[/\\]/).some((segment) => VENDORED_DIRS.has(segment));
}

function projectRootFor(file: string): string {
  return basename(file) === "gradle-wrapper.properties"
    ? dirname(dirname(dirname(file)))
    : dirname(file);
}

async function distributionVersion(file: string): Promise<string | null> {
  let text: string;
  try {
    text = await readFile(file, "utf8");
  } catch {
    return null;
  }
  for (const line of text.split("\n")) {
    const match = DISTRIBUTION_URL.exec(line);
    if (match?.[1]) return match[1];
  }
  return null;
}
