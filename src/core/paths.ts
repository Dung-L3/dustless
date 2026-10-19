import { homedir, tmpdir } from "node:os";
import { readdir } from "node:fs/promises";
import { lstatSync, realpathSync } from "node:fs";
import { dirname, join, parse, resolve, sep } from "node:path";
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

type ResolveResult =
  | { paths: string[]; error?: undefined }
  | { paths: string[]; error: { code: string; pattern: string } };

export async function resolvePattern(pattern: string): Promise<ResolveResult> {
  const expanded = expand(pattern);
  if (!expanded.includes("*")) {
    const full = resolved(expanded);
    const ok = await exists(full);
    if (ok) return { paths: [full] };
    try {
      const { stat } = await import("node:fs/promises");
      await stat(full);
      return { paths: [], error: { code: "EACCES", pattern } };
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code ?? "error";
      return { paths: [], error: { code, pattern } };
    }
  }
  const star = expanded.indexOf("*");
  const base = resolved(expanded.slice(0, star).replace(/[/\\]$/, ""));
  const suffix = expanded.slice(star + 1).replace(/^[/\\]/, "");
  let entries: string[];
  try {
    entries = (await readdir(base, { withFileTypes: true }))
      .filter((e) => e.isDirectory() || e.isSymbolicLink())
      .map((e) => e.name);
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code ?? "error";
    return { paths: [], error: { code, pattern } };
  }
  const out: string[] = [];
  for (const name of entries) {
    const full = join(base, name, suffix);
    if (suffix && !(await exists(full))) continue;
    out.push(resolved(full));
  }
  return { paths: out.sort() };
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
  const normalized = path.replace(/[\\/]+/g, "/").replace(/\/+$/, "");
  return RED_PATTERNS.some((re) => re.test(normalized));
}

export function isRedReal(path: string): boolean {
  if (isRed(path)) return true;
  try {
    return isRed(realpathSync(path));
  } catch (err) {
    return (err as NodeJS.ErrnoException).code !== "ENOENT";
  }
}

export type RealRefusal = "red" | "unresolvable" | "protected" | "symlinked" | "changed";
export type RealGuard = { real: string } | { refused: RealRefusal };

function canonicalReal(path: string): string {
  const mac = platform === "mac" ? path.replace(/^\/private\/(var|tmp|etc)(?=\/|$)/, "/$1") : path;
  return platform === "win" ? mac.toLowerCase() : mac;
}

function homeReal(): string {
  try {
    return realpathSync(HOME);
  } catch {
    return HOME;
  }
}

function isProtectedReal(real: string): boolean {
  const target = canonicalReal(real);
  const home = canonicalReal(homeReal());
  if (target === parse(target).root) return true;
  return target === home || home.startsWith(target.endsWith(sep) ? target : target + sep);
}

function goesThroughSymlink(full: string, real: string): boolean {
  try {
    if (lstatSync(full).isSymbolicLink()) return false;
  } catch {
    return false;
  }
  return canonicalReal(real) !== canonicalReal(full);
}

export function realGuard(path: string): RealGuard {
  const full = resolve(path);
  if (isRed(full)) return { refused: "red" };
  let real: string;
  try {
    real = realpathSync(full);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== "ENOENT") return { refused: "unresolvable" };
    const parent = dirname(full);
    try {
      const realParent = realpathSync(parent);
      if (isRed(realParent)) return { refused: "red" };
      if (canonicalReal(realParent) !== canonicalReal(parent)) return { refused: "symlinked" };
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== "ENOENT") return { refused: "unresolvable" };
      try {
        if (lstatSync(parent).isSymbolicLink()) return { refused: "symlinked" };
      } catch {
        return { refused: "unresolvable" };
      }
    }
    return { real: full };
  }
  if (isRed(real)) return { refused: "red" };
  if (isProtectedReal(real)) return { refused: "protected" };
  if (goesThroughSymlink(full, real)) return { refused: "symlinked" };
  return { real };
}

export function refusalText(reason: RealRefusal): string {
  if (reason === "red") return "từ chối: nằm trong danh sách đỏ";
  if (reason === "unresolvable") return "từ chối: không xác minh được đường dẫn thực";
  if (reason === "protected") return "từ chối: là HOME, thư mục cha của HOME hoặc gốc hệ thống";
  if (reason === "symlinked") return "từ chối: đường dẫn đi qua liên kết tượng trưng";
  return "từ chối: đường dẫn thay đổi trong lúc chờ xoá";
}
