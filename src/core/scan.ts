import { lstat, readdir } from "node:fs/promises";
import { join, resolve } from "node:path";
import type { Finding, Rule, ScanReport, Tier, TierStat } from "../types.ts";
import { isRed, matchesBasename, pathsForRule, platform, resolvePattern } from "./paths.ts";
import { loadRules } from "./rules.ts";
import { verify } from "./verify/index.ts";
import { freeSpace } from "./space.ts";

const WALKS = 8;
const DAY = 86_400_000;

type Candidate = { rule: Rule; path: string };
type Tree = { bytes: number; mtime: number; atime: number };

export async function scan(opts: { roots?: string[]; minBytes?: number } = {}): Promise<ScanReport> {
  const started = Date.now();
  const freeBefore = await freeSpace(opts.roots?.[0]);
  const found: Finding[] = [];
  await pool(await candidates(await loadRules(), opts.roots), WALKS, async ({ rule, path }) => {
    const finding = await inspect(rule, path);
    if (finding && finding.bytes >= (opts.minBytes ?? 0)) found.push(finding);
  });
  found.sort((a, b) => b.bytes - a.bytes);
  const totals = tally(found);
  return {
    findings: found,
    totals,
    reclaimable: totals.green.bytes + totals.yellow.bytes,
    freeBefore,
    platform,
    scannedMs: Date.now() - started,
  };
}

async function candidates(rules: Rule[], roots?: string[]): Promise<Candidate[]> {
  const prefixes = roots?.map((root) => resolve(root));
  const seen = new Set<string>();
  const out: Candidate[] = [];
  for (const rule of rules) {
    const hits = (await Promise.all(pathsForRule(rule).map((pattern) => resolvePattern(pattern)))).flat();
    for (const path of hits) {
      if (seen.has(path) || isRed(path)) continue;
      if (!matchesBasename(path, rule.match)) continue;
      if (prefixes && !prefixes.some((prefix) => path.startsWith(prefix))) continue;
      seen.add(path);
      out.push({ rule, path });
    }
  }
  return out;
}

async function pool(items: Candidate[], limit: number, work: (item: Candidate) => Promise<void>) {
  let cursor = 0;
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (cursor < items.length) {
        const item = items[cursor++];
        if (item) await work(item);
      }
    }),
  );
}

async function inspect(rule: Rule, path: string): Promise<Finding | null> {
  const tree = await walk(path);
  if (tree.bytes === 0) return null;
  const ageDays = Math.max(0, (Date.now() - tree.mtime) / DAY);
  const notes: string[] = [];
  let tier: Tier = rule.tier;
  let verified = true;
  let blocked = false;
  if (rule.minAgeDays !== undefined && ageDays < rule.minAgeDays) {
    tier = "yellow";
    notes.push(`mới ${ageDays.toFixed(1)} ngày, rule yêu cầu ≥ ${rule.minAgeDays} ngày`);
  }
  if (rule.requireVerify) {
    const verdict = await verify(rule, path);
    verified = verdict.ok;
    if (!verdict.ok) {
      tier = "yellow";
      blocked = true;
      notes.push(`KHÔNG XÓA: ${verdict.note}`);
    }
  }
  return {
    ruleId: rule.id,
    tier,
    desc: rule.desc,
    path,
    bytes: tree.bytes,
    mtime: tree.mtime,
    atime: tree.atime,
    ageDays,
    verified,
    blocked,
    note: notes.join(" · "),
  };
}

async function walk(root: string): Promise<Tree> {
  const rootMeta = await lstat(root).catch(() => null);
  if (!rootMeta) return { bytes: 0, mtime: 0, atime: 0 };
  const tree: Tree = { bytes: 0, mtime: rootMeta.mtimeMs, atime: rootMeta.atimeMs };
  if (rootMeta.isFile()) {
    tree.bytes = rootMeta.size;
    return tree;
  }
  const stack = [root];
  while (stack.length) {
    const dir = stack.pop();
    if (!dir) break;
    const entries = await readdir(dir, { withFileTypes: true }).catch(() => null);
    if (!entries) continue;
    const files: string[] = [];
    for (const entry of entries) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) stack.push(full);
      else if (entry.isFile()) files.push(full);
    }
    const stats = await Promise.all(files.map((file) => lstat(file).catch(() => null)));
    for (const meta of stats) {
      if (!meta) continue;
      tree.bytes += meta.size;
      if (meta.mtimeMs > tree.mtime) tree.mtime = meta.mtimeMs;
      if (meta.atimeMs > tree.atime) tree.atime = meta.atimeMs;
    }
  }
  return tree;
}

function tally(findings: Finding[]): Record<Tier, TierStat> {
  const totals: Record<Tier, TierStat> = {
    green: { count: 0, bytes: 0 },
    yellow: { count: 0, bytes: 0 },
    red: { count: 0, bytes: 0 },
    blocked: { count: 0, bytes: 0 },
  };
  for (const finding of findings) {
    if (finding.blocked) {
      totals.blocked.count += 1;
      totals.blocked.bytes += finding.bytes;
      continue;
    }
    const bucket = totals[finding.tier];
    bucket.count += 1;
    bucket.bytes += finding.bytes;
  }
  return totals;
}