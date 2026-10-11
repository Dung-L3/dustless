import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmod, lstat, mkdir, mkdtemp, readFile, readdir, rm, stat, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, relative, resolve, sep } from "node:path";

export const REPO = resolve(import.meta.dir, "..", "..");
export const BINARY = join(REPO, "dist", process.platform === "win32" ? "dustless.exe" : "dustless");
export const DAY = 86_400_000;
export const MB = 1024 * 1024;
export const VERSION = JSON.parse(
  await readFile(join(REPO, "package.json"), "utf8"),
).version as string;

// Every e2e test drives the compiled binary. Build it once here if it is
// missing, so the suite does not depend on CI's step order or on which test
// file the runner happens to load first. That missing guarantee made the
// deep-tree and concurrent-scan tests fail on the macOS and Windows runners,
// where the binary had not been produced before those files ran.
if (!(await stat(BINARY).then(() => true, () => false))) {
  const built = await Bun.$`bun run build`.cwd(REPO).quiet().nothrow();
  if (built.exitCode !== 0 || !(await stat(BINARY).then(() => true, () => false))) {
    throw new Error(`could not build the e2e binary ${BINARY} (exit ${built.exitCode}):\n${built.stderr.toString()}`);
  }
}

const TMP = resolve(tmpdir());
const TIMEOUT_MS = 60_000;

export type Finding = {
  ruleId: string;
  tier: string;
  desc: string;
  path: string;
  bytes: number;
  ageDays: number;
  verified: boolean;
  blocked: boolean;
  note: string;
};

export type ScanReport = {
  findings: Finding[];
  totals: Record<string, { count: number; bytes: number }>;
  reclaimable: number;
  freeBefore: number;
  platform: string;
  scannedMs: number;
};

export type Outcome = {
  ruleId: string;
  tier: string;
  path: string;
  status: "deleted" | "skipped" | "failed";
  bytes: number;
  detail: string;
};

export type ApplyReport = {
  outcomes: Outcome[];
  freed: number;
  freeBefore: number;
  freeAfter: number;
  elapsedMs: number;
};

export type Result = { code: number; stdout: string; stderr: string };

export function measuredFreed(report: Pick<ApplyReport, "freeBefore" | "freeAfter">): number {
  return Math.max(0, report.freeAfter - report.freeBefore);
}

export type Sandbox = {
  home: string;
  outside: string;
  run: (args: string[], opts?: { cwd?: string }) => Promise<Result>;
  dispose: () => Promise<void>;
};

export function assertSandboxed(path: string, root: string): string {
  const full = resolve(path);
  const base = resolve(root);
  if (full !== base && !full.startsWith(base + sep)) {
    throw new Error(`out-of-sandbox path refused: ${full} is not under ${base}`);
  }
  if (full === "/" || full === resolve("/Users") || full.startsWith(resolve("/Users/mac"))) {
    throw new Error(`refusing protected path: ${full}`);
  }
  return full;
}

export function assertTempRoot(path: string): string {
  const full = resolve(path);
  if (!full.startsWith(TMP + sep)) throw new Error(`not a throwaway temp path: ${full}`);
  if (full.startsWith(resolve("/Users/mac"))) throw new Error(`refusing real home: ${full}`);
  return full;
}

const live: Sandbox[] = [];

export async function cleanupAll(): Promise<void> {
  while (live.length) await live.pop()?.dispose();
}

export async function sandbox(label: string): Promise<Sandbox> {
  const home = assertTempRoot(await mkdtemp(join(TMP, `dustless-e2e-${label}-`)));
  const outside = assertTempRoot(await mkdtemp(join(TMP, `dustless-outside-${label}-`)));
  const env: Record<string, string> = {
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
    HOME: home,
    XDG_CONFIG_HOME: join(home, ".config"),
    NO_COLOR: "1",
    TMPDIR: TMP,
  };
  const run = (args: string[], opts: { cwd?: string } = {}): Promise<Result> => {
    assertTempRoot(env["HOME"] as string);
    for (const arg of args) {
      if (arg.startsWith("/")) assertSandboxed(arg, home);
    }
    return exec(args, env, opts.cwd ?? "/");
  };
  const dispose = async (): Promise<void> => {
    const at = live.indexOf(box);
    if (at >= 0) live.splice(at, 1);
    for (const dir of [home, outside]) {
      spawnSync("chmod", ["-R", "u+rwX", dir], { stdio: "ignore" });
      await rm(dir, { recursive: true, force: true });
    }
  };
  const box: Sandbox = { home, outside, run, dispose };
  live.push(box);
  return box;
}

export function exec(args: string[], env: Record<string, string>, cwd = "/"): Promise<Result> {
  return new Promise((done) => {
    const child = spawn(BINARY, args, { env, cwd, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      stderr += `\nTIMEOUT after ${TIMEOUT_MS}ms`;
      child.kill("SIGKILL");
    }, TIMEOUT_MS);
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("error", (err: Error) => done({ code: -1, stdout, stderr: err.message }));
    child.on("close", (code) => {
      clearTimeout(timer);
      done({ code: code ?? -1, stdout, stderr });
    });
  });
}

export async function plant(dir: string, bytes: number, files = 4): Promise<number> {
  const target = resolve(dir);
  await mkdir(target, { recursive: true });
  const per = Math.floor(bytes / files);
  let written = 0;
  for (let i = 0; i < files; i++) {
    const chunk = i === files - 1 ? bytes - written : per;
    await writeFile(join(target, `blob-${i}.bin`), Buffer.alloc(chunk, 0x41));
    written += chunk;
  }
  return written;
}

export async function age(dir: string, days: number): Promise<void> {
  const at = new Date(Date.now() - days * DAY);
  const stack = [resolve(dir)];
  while (stack.length) {
    const current = stack.pop();
    if (current === undefined) continue;
    await utimes(current, at, at).catch(() => undefined);
    const entries = await readdir(current, { withFileTypes: true }).catch(() => []);
    for (const entry of entries) {
      if (entry.isDirectory() || entry.isFile()) stack.push(join(current, entry.name));
    }
  }
}

export async function userRules(home: string, body: string): Promise<string> {
  const dir = assertSandboxed(join(home, ".config", "dustless"), home);
  await mkdir(dir, { recursive: true });
  const file = join(dir, "rules.yaml");
  await writeFile(file, body);
  return file;
}

export async function makeWritable(dir: string): Promise<void> {
  spawnSync("chmod", ["-R", "u+rwX", dir], { stdio: "ignore" });
  await chmod(dir, 0o755).catch(() => undefined);
}

export function scanJson(stdout: string): ScanReport {
  const parsed = JSON.parse(stdout) as ScanReport;
  return parsed;
}

export async function treeBytes(dir: string): Promise<number> {
  let total = 0;
  const stack = [resolve(dir)];
  while (stack.length) {
    const current = stack.pop();
    if (current === undefined) continue;
    const entries = await readdir(current, { withFileTypes: true }).catch(() => []);
    for (const entry of entries) {
      const full = join(current, entry.name);
      if (entry.isDirectory()) stack.push(full);
      else total += (await lstat(full)).size;
    }
  }
  return total;
}

export async function digest(dir: string): Promise<string> {
  const hash = createHash("sha256");
  const parts: string[] = [];
  const stack = [resolve(dir)];
  while (stack.length) {
    const current = stack.pop();
    if (current === undefined) continue;
    const entries = await readdir(current, { withFileTypes: true });
    for (const entry of entries) {
      const full = join(current, entry.name);
      const rel = relative(resolve(dir), full);
      if (entry.isDirectory()) {
        parts.push(`d ${rel}`);
        stack.push(full);
      } else {
        parts.push(`f ${rel} ${(await lstat(full)).size} ${createHash("sha256").update(await readFile(full)).digest("hex")}`);
      }
    }
  }
  for (const part of parts.sort()) hash.update(part);
  return hash.digest("hex");
}

export function findByRule(report: ScanReport, ruleId: string, pathSuffix: string): Finding | undefined {
  return report.findings.find((f) => f.ruleId === ruleId && f.path.endsWith(pathSuffix));
}

export function applyJson(stdout: string): ApplyReport {
  return JSON.parse(stdout) as ApplyReport;
}

export function gradleWrapper(file: string, version: string): Promise<void> {
  return writeFile(
    file,
    `distributionBase=GRADLE_USER_HOME\ndistributionPath=wrapper/dists\ndistributionUrl=https\\://services.gradle.org/distributions/gradle-${version}-bin.zip\nzipStoreBase=GRADLE_USER_HOME\n`,
  );
}
export function currentPlatform(): "mac" | "win" | "linux" {
  if (process.platform === "darwin") return "mac";
  if (process.platform === "win32") return "win";
  return "linux";
}
