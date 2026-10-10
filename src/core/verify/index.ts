import { basename } from "node:path";
import type { Rule } from "../../types.ts";
import { gradleVersionUnused } from "./gradle.ts";
import { gitClean, gitIgnored } from "./git.ts";

export type VerifyResult = { ok: boolean; note: string };

export async function verify(rule: Rule, path: string): Promise<VerifyResult> {
  switch (rule.requireVerify) {
    case undefined:
      return { ok: true, note: "no verification required" };
    case "gradle_version_unused":
      return await gradleVersionUnused(basename(path));
    case "git_clean":
      return await gitClean(path);
    case "not_in_gitignore":
      return await gitIgnored(path);
  }
}
