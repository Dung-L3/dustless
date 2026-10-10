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
  if (!root) return { ok: true, note: "not a git repo" };

  const gitDir = await resolveGitDir(root);
  if (gitDir !== null) {
    for (const marker of IN_PROGRESS_MARKERS) {
      if (await exists(join(gitDir, marker))) {
        return { ok: false, note: `git operation in progress: ${marker}` };
      }
    }
  }

  const status = await git(root, ["status", "--porcelain"]);
  if (status === null) return { ok: false, note: "git status failed, cannot verify" };
  if (status.output !== "") return { ok: false, note: "git has uncommitted changes" };

  const unpushed = await git(root, ["log", "@{u}..HEAD", "--oneline"]);
  if (unpushed !== null && unpushed.output !== "") {
    return { ok: false, note: "git has unpushed commits" };
  }

  return { ok: true, note: "git working tree is clean" };
}

export async function gitIgnored(target: string): Promise<VerifyResult> {
  const root = await findRepoRoot(target);
  if (!root) return { ok: true, note: "not a git repo" };
  const exit = await gitExit(root, ["check-ignore", "-q", "--", resolve(target)]);
  if (exit === null) return { ok: false, note: "git check-ignore failed, cannot verify" };
  return exit === 0
    ? { ok: false, note: "path is ignored by git" }
    : { ok: true, note: "path is tracked by git" };
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
