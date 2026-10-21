import { homedir } from "node:os";
import { readdir, stat } from "node:fs/promises";
import type { Dirent } from "node:fs";
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

export const HOME = homedir();

export type GlobLimits = { maxDepth: number; maxEntries: number };

export const GLOB_LIMITS: GlobLimits = { maxDepth: 12, maxEntries: 20_000 };

export type PatternVerdict = { ok: true } | { ok: false; kind: "protected" | "unsupported"; reason: string };

const SEPARATOR = platform === "win" ? /[/\\]/ : /\//;

type Slot = string | null;

function splitSegments(text: string): string[] {
  return text.split(SEPARATOR).filter((part) => part.length > 0);
}

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function globMatcher(segment: string): RegExp {
  const source = segment.split("*").map(escapeRegExp).join("[^/]*");
  return new RegExp(`^${source}$`);
}

function patternSlots(pattern: string): { slots: Slot[]; anchored: boolean } | { error: string } {
  const anchored = /^~/.test(pattern);
  const expanded = expand(pattern);
  const text = platform === "win" ? expanded.replace(/\\/g, "/") : expanded;
  let base: Slot[] = [];
  let rest = text;
  let absolute = false;
  if (/^[A-Za-z]:/.test(text)) {
    absolute = true;
    base = [text.slice(0, 2)];
    rest = text.slice(2);
  } else if (text.startsWith("/")) {
    absolute = true;
  } else {
    base = splitSegments(resolve(".")) as Slot[];
  }
  const slots: Slot[] = [...base];
  for (const segment of splitSegments(rest)) {
    if (segment === ".") continue;
    if (segment === "..") {
      const last = slots[slots.length - 1];
      if (last === undefined) {
        if (!absolute) return { error: "path tương đối đi ra ngoài gốc hệ thống" };
        continue;
      }
      if (last === null) return { error: ".. sau ký tự đại diện không thể chứng minh an toàn" };
      slots.pop();
      continue;
    }
    if (segment.includes("**")) return { error: "** không được hỗ trợ, dùng từng đoạn * riêng biệt" };
    slots.push(segment.includes("*") ? null : segment);
  }
  return { slots, anchored };
}

const homeSlots: string[] = splitSegments(resolve(HOME));

function compatible(slots: Slot[], target: string[]): boolean {
  if (slots.length !== target.length) return false;
  for (let index = 0; index < slots.length; index += 1) {
    const slot = slots[index];
    if (slot === null) continue;
    if (slot !== target[index]) return false;
  }
  return true;
}

export function patternVerdict(pattern: string): PatternVerdict {
  const parsed = patternSlots(pattern);
  if ("error" in parsed) return { ok: false, kind: "unsupported", reason: parsed.error };
  const { slots, anchored } = parsed;
  if (splitSegments(expand(pattern)).length > GLOB_LIMITS.maxDepth) {
    return { ok: false, kind: "unsupported", reason: `path quá sâu (tối đa ${GLOB_LIMITS.maxDepth} đoạn)` };
  }
  const home = homeSlots;
  if (slots.length === 0) return { ok: false, kind: "protected", reason: "phạm vi rule là gốc hệ thống" };
  if (compatible(slots, home)) return { ok: false, kind: "protected", reason: "phạm vi rule là chính $HOME" };
  for (let length = 1; length < home.length; length += 1) {
    if (compatible(slots, home.slice(0, length))) {
      return { ok: false, kind: "protected", reason: "phạm vi rule là thư mục cha của $HOME" };
    }
  }
  if (slots.length === home.length + 1 && compatible(slots.slice(0, home.length), home) && slots[home.length] === null) {
    return { ok: false, kind: "protected", reason: "phạm vi rule chọn thư mục con trực tiếp của $HOME" };
  }
  if (anchored && !(slots.length > home.length && compatible(slots.slice(0, home.length), home))) {
    return { ok: false, kind: "protected", reason: "phạm vi rule đi ra ngoài $HOME" };
  }
  return { ok: true };
}

export function patternsVerdict(patterns: string[]): PatternVerdict {
  for (const pattern of patterns) {
    const verdict = patternVerdict(pattern);
    if (!verdict.ok) return verdict;
  }
  return { ok: true };
}

type ResolveResult =
  | { paths: string[]; error?: undefined }
  | { paths: string[]; error: { code: string; pattern: string } };

type Step = { kind: "literal"; value: string } | { kind: "glob"; matcher: RegExp };

function planSteps(pattern: string): { base: string; steps: Step[] } {
  const expanded = expand(pattern);
  const text = platform === "win" ? expanded.replace(/\\/g, "/") : expanded;
  const drive = /^[A-Za-z]:/.test(text) ? text.slice(0, 2) : "";
  const rest = drive ? text.slice(2) : text;
  const root = drive ? `${drive}${sep}` : rest.startsWith(sep) ? sep : "";
  const segments = splitSegments(rest);
  let index = 0;
  while (index < segments.length) {
    const segment = segments[index];
    if (segment === undefined || segment.includes("*")) break;
    index += 1;
  }
  const prefix = segments.slice(0, index);
  const base = prefix.length === 0 ? resolve(root || ".") : resolve(root + prefix.join(sep));
  const steps: Step[] = segments.slice(index).map((segment) =>
    segment.includes("*") ? { kind: "glob", matcher: globMatcher(segment) } : { kind: "literal", value: segment },
  );
  return { base, steps };
}

export async function resolvePattern(pattern: string, limits: GlobLimits = GLOB_LIMITS): Promise<ResolveResult> {
  const plan = planSteps(pattern);
  if (!plan.steps.some((step) => step.kind === "glob")) {
    const full = resolved(expand(pattern));
    const ok = await exists(full);
    if (ok) return { paths: [full] };
    try {
      await stat(full);
      return { paths: [], error: { code: "EACCES", pattern } };
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code ?? "error";
      return { paths: [], error: { code, pattern } };
    }
  }
  let current = [plan.base];
  let budget = limits.maxEntries;
  for (const step of plan.steps) {
    const next: string[] = [];
    for (const dir of current) {
      if (step.kind === "literal") {
        const full = join(dir, step.value);
        if (await exists(full)) next.push(full);
        continue;
      }
      let entries: Dirent[];
      try {
        entries = await readdir(dir, { withFileTypes: true });
      } catch (err) {
        const code = (err as NodeJS.ErrnoException).code ?? "error";
        return { paths: [], error: { code, pattern } };
      }
      budget -= entries.length;
      if (budget < 0) return { paths: [], error: { code: "EBUDGET", pattern } };
      for (const entry of entries) {
        if (!entry.isDirectory() && !entry.isSymbolicLink()) continue;
        if (!step.matcher.test(entry.name)) continue;
        next.push(join(dir, entry.name));
      }
    }
    current = next;
    if (!current.length) break;
  }
  return { paths: current.map(resolved).sort() };
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
  return [...new Set(patterns)];
}

export function matchesBasename(path: string, match?: string): boolean {
  if (!match) return true;
  const name = path.split(/[/\\]/).filter(Boolean).pop() ?? "";
  return new RegExp(match).test(name);
}

const RED_PATTERNS: RegExp[] = [
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

export function isProtectedPath(path: string): boolean {
  const full = resolve(path);
  let real = full;
  try {
    real = realpathSync(full);
  } catch {
    real = full;
  }
  return isProtectedReal(real);
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
