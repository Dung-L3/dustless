import { execFile } from "node:child_process";
import { readFile, stat } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { promisify } from "node:util";
import { exists } from "../paths.ts";
import type { VerifyResult } from "./index.ts";

const execFileAsync = promisify(execFile);
const TIMEOUT_MS = 5000;
const GITDIR = /^gitdir:\s*(.+)$/m;
const IN_PROGRESS_MARKERS = [
  "MERGE_HEAD",
  "CHERRY_PICK_HEAD",
  "REVERT_HEAD",
  "BISECT_LOG",
  "rebase-merge",
  "rebase-apply",
];

export async function findRepoRoot(start: string): Promise<string | null> {
  let current = resolve(start);
  for (;;) {
    if (await exists(join(current, ".git"))) return current;
    const parent = dirname(current);
    if (parent === current) return null;
    current = parent;
  }
}

export async function gitClean(target: string): Promise<VerifyResult> {
  const root = await findRepoRoot(target);
  if (!root) return { ok: true };

  const gitDir = await resolveGitDir(root);
  if (gitDir !== null) {
    for (const marker of IN_PROGRESS_MARKERS) {
      if (await exists(join(gitDir, marker))) {
        return { ok: false, cause: "git_in_progress", params: { marker } };
      }
    }
  }

  const status = await git(root, ["status", "--porcelain"]);
  if (status === null) return { ok: false, cause: "git_unverifiable" };
  if (status.output !== "") return { ok: false, cause: "git_dirty" };

  const unpushed = await git(root, ["log", "@{u}..HEAD", "--oneline"]);
  if (unpushed !== null && unpushed.output !== "") {
    return { ok: false, cause: "git_unpushed" };
  }

  return { ok: true };
}

export async function gitIgnored(target: string): Promise<VerifyResult> {
  const root = await findRepoRoot(target);
  if (!root) return { ok: true };
  const exit = await gitExit(root, ["check-ignore", "-q", "--", resolve(target)]);
  if (exit === null) return { ok: false, cause: "git_unverifiable_ignore" };
  if (exit === 1) return { ok: true };
  if (exit === 0) return { ok: false, cause: "git_ignored" };
  return { ok: false, cause: "git_unverifiable_ignore", params: { exit: String(exit) } };
}

async function git(cwd: string, args: string[]): Promise<{ output: string } | null> {
  try {
    const { stdout } = await execFileAsync("git", args, { cwd, timeout: TIMEOUT_MS, windowsHide: true });
    return { output: stdout.trim() };
  } catch {
    return null;
  }
}

async function gitExit(cwd: string, args: string[]): Promise<number | null> {
  try {
    await execFileAsync("git", args, { cwd, timeout: TIMEOUT_MS, windowsHide: true });
    return 0;
  } catch (error) {
    const code = (error as { code?: unknown }).code;
    return typeof code === "number" ? code : null;
  }
}

async function resolveGitDir(root: string): Promise<string | null> {
  const dot = join(root, ".git");
  try {
    const info = await stat(dot);
    if (info.isDirectory()) return dot;
    const pointer = GITDIR.exec(await readFile(dot, "utf8"));
    return pointer?.[1] ? resolve(root, pointer[1].trim()) : null;
  } catch {
    return null;
  }
}
