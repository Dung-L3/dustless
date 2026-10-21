import { basename } from "node:path";
import type { Rule } from "../../types.ts";
import { gradleVersionUnused } from "./gradle.ts";
import { gitClean, gitIgnored } from "./git.ts";
import { isLiveDependencyTree } from "./node.ts";

export type VerifyResult = { ok: boolean; note: string };

const CACHE_TTL_MS = 30_000;
const cache = new Map<string, { at: number; result: VerifyResult }>();

function cached(key: string): VerifyResult | null {
  const hit = cache.get(key);
  if (!hit) return null;
  if (Date.now() - hit.at >= CACHE_TTL_MS) {
    cache.delete(key);
    return null;
  }
  return hit.result;
}

function remember(key: string, result: VerifyResult): VerifyResult {
  cache.set(key, { at: Date.now(), result });
  return result;
}

export async function verify(rule: Rule, path: string): Promise<VerifyResult> {
  if (basename(path) === "node_modules") {
    const live = await isLiveDependencyTree(path);
    if (!live) return { ok: false, note: "dependency tree looks stale against its package.json" };
  }
  switch (rule.requireVerify) {
    case undefined:
      return { ok: true, note: "no verification required" };
    case "gradle_version_unused": {
      const key = `gradle:${basename(path)}`;
      const hit = cached(key);
      if (hit) return hit;
      return remember(key, await gradleVersionUnused(basename(path)));
    }
    case "git_clean":
      return await gitClean(path);
    case "not_in_gitignore":
      return await gitIgnored(path);
  }
}
