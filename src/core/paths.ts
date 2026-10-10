import { homedir, tmpdir } from "node:os";
import { readdir } from "node:fs/promises";
import { join, resolve } from "node:path";
import type { Platform, Rule } from "../types.ts";

export const platform: Platform =
  process.platform === "darwin"
    ? "mac"
    : process.platform === "win32"
      ? "win"
      : "linux";

export function expand(pattern: string): string {
  let out = pattern;
  if (platform === "win") {
    out = out.replace(/%([A-Za-z_][A-Za-z0-9_]*)%/g, (_, key: string) => process.env[key] ?? "");
  }
  return out.replace(/^~(?=$|[/\\])/, homedir());
}

export async function resolvePattern(pattern: string): Promise<string[]> {
  const expanded = expand(pattern);
  if (!expanded.includes("*")) {
    return await exists(resolved(expanded)) ? [resolved(expanded)] : [];
  }
  const star = expanded.indexOf("*");
  const base = resolved(expanded.slice(0, star).replace(/[/\\]$/, ""));
  const suffix = expanded.slice(star + 1).replace(/^[/\\]/, "");
  let entries: string[];
  try {
    entries = (await readdir(base, { withFileTypes: true }))
      .filter((e) => e.isDirectory() || e.isSymbolicLink())
      .map((e) => e.name);
  } catch {
    return [];
  }
  const out: string[] = [];
  for (const name of entries) {
    const full = join(base, name, suffix);
    if (suffix && !(await exists(full))) continue;
    out.push(full);
  }
  return out.sort();
}

function resolved(p: string): string {
  return resolve(p);
}

export async function exists(path: string): Promise<boolean> {
  try {
    await readdir(path);
    return true;
  } catch {
    try {
      const { stat } = await import("node:fs/promises");
      return (await stat(path)).isFile();
    } catch {
      return false;
    }
  }
}

export function pathsForRule(rule: Rule): string[] {
  const patterns = Object.entries(rule.paths)
    .filter(([key]) => key === "all" || key === platform)
    .flatMap(([, value]) => (Array.isArray(value) ? value : [value]))
    .filter((value): value is string => Boolean(value));
  return [...new Set(patterns.map(expand))];
}

export function matchesBasename(path: string, match?: string): boolean {
  if (!match) return true;
  const name = path.split(/[/\\]/).filter(Boolean).pop() ?? "";
  return new RegExp(match).test(name);
}

export const HOME = homedir();
export const TMP = tmpdir();

export const RED_PATTERNS: RegExp[] = [
  /Keychains?/i,
  /\/Mail(\.v2)?\//i,
  /Mail(\.v2)?$/i,
  /iCloud/i,
  /-wal$/i,
  /-shm$/i,
  /Preferences$/i,
  /\.git(\/|$)/i,
  /Documents/i,
  /Desktop/i,
  /Pictures/i,
  /Movies/i,
  /Music/i,
  /Contacts/i,
  /Reminders/i,
  /Calendar/i,
  /Finance/i,
  /Passes/i,
  /Keynotes/i,
  /Messages/i,
  /Application Support\/com\.apple\.(Photos|MobileSync|Notes|Trial)/i,
];

export function isRed(path: string): boolean {
  return RED_PATTERNS.some((re) => re.test(path));
}