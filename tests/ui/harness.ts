import { spawn, spawnSync } from "node:child_process";
import {
  appendFile,
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { existsSync } from "node:fs";

export const REPO = resolve(import.meta.dir, "..", "..");
const ARTIFACTS = join(REPO, "artifacts", "ui");
const DRIVER_SRC = join(import.meta.dir, "AXDriver.swift");
const DRIVER_BIN = join(REPO, ".ui-bin", "axdriver");
const APP_NAME = "DustlessE2E";
const BUNDLE_ID = "dev.dustless.e2e";
const FIXTURES = join(import.meta.dir, "fixtures");
const TEST_PREFS = join(homedir(), "Library", "Preferences", `${BUNDLE_ID}.plist`);

export async function removeTestDomainPrefs(): Promise<void> {
  spawnSync("defaults", ["delete", BUNDLE_ID], { stdio: "ignore" });
  await rm(TEST_PREFS, { force: true });
}

export type DriverResult = Record<string, unknown> & {
  role?: string;
  identifier?: string;
  title?: string;
  value?: string;
  enabled?: boolean;
  selected?: boolean;
  x?: number;
  y?: number;
  width?: number;
  height?: number;
  actions?: string[];
};

export type LaunchOptions = {
  label: string;
  intercepted?: "net" | "awdl" | "both";
  language?: "en" | "vi" | "zh";
};

export type Seed = (app: UiApp) => Promise<void> | void;

function run(command: string, args: string[], env?: Record<string, string>) {
  return spawnSync(command, args, {
    cwd: REPO,
    env: { ...process.env, ...env },
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

export function uiTestingEnabled(): boolean {
  return process.platform === "darwin" && process.env["DUSTLESS_UI"] === "1";
}

export async function driverTrusted(): Promise<boolean> {
  if (process.platform !== "darwin") return false;
  await ensureDriver();
  const result = run(DRIVER_BIN, ["trusted"]);
  if (result.status !== 0) {
    throw new Error(`AX driver failed (${result.status}): ${result.stderr}`);
  }
  const parsed = JSON.parse(result.stdout) as { trusted?: unknown };
  if (typeof parsed.trusted !== "boolean") {
    throw new Error(`AX driver returned an invalid trust result: ${result.stdout}`);
  }
  return parsed.trusted;
}

export async function ensureDriver(): Promise<void> {
  const source = await stat(DRIVER_SRC);
  const binary = await stat(DRIVER_BIN).catch(() => null);
  if (binary && binary.mtimeMs >= source.mtimeMs) return;
  await mkdir(dirname(DRIVER_BIN), { recursive: true });
  const built = run("swiftc", ["-O", "-swift-version", "5", DRIVER_SRC, "-o", DRIVER_BIN]);
  if (built.status !== 0) throw new Error(`failed to build AX driver:\n${built.stderr}`);
}

export type TestApp = { path: string; executable: string; version: string };

export async function buildTestApp(): Promise<TestApp> {
  await mkdir(join(REPO, ".ui-bin"), { recursive: true });
  const built = join(ARTIFACTS, "build", "Dustless.app");
  await rm(built, { recursive: true, force: true });
  const engineBuild = run("bun", ["run", "build"]);
  if (engineBuild.status !== 0) {
    throw new Error(`build failed:\n${engineBuild.stdout}\n${engineBuild.stderr}`);
  }
  const appBuild = run("bun", ["run", "bundle:mac"], {
    DUSTLESS_UI_TESTING: "1",
    DUSTLESS_BUNDLE_OUT: built,
  });
  if (appBuild.status !== 0) {
    throw new Error(`bundle:mac failed:\n${appBuild.stdout}\n${appBuild.stderr}`);
  }
  if (!existsSync(built)) throw new Error(`missing ${built}`);

  const app = join(ARTIFACTS, "app", `${APP_NAME}.app`);
  await rm(app, { recursive: true, force: true });
  await mkdir(dirname(app), { recursive: true });
  const copied = run("ditto", [built, app]);
  if (copied.status !== 0) throw new Error(`ditto failed:\n${copied.stderr}`);

  const info = join(app, "Contents", "Info.plist");
  const set = (key: string, value: string) => {
    const result = run("plutil", ["-replace", key, "-string", value, info]);
    if (result.status !== 0) throw new Error(`plutil ${key} failed:\n${result.stderr}`);
  };
  set("CFBundleIdentifier", BUNDLE_ID);
  set("CFBundleName", APP_NAME);
  set("CFBundleDisplayName", APP_NAME);
  set("CFBundleExecutable", APP_NAME);

  const macos = join(app, "Contents", "MacOS");
  const oldExecutable = join(macos, "Dustless");
  const executable = join(macos, APP_NAME);
  await rm(executable, { force: true });
  await rename(oldExecutable, executable);
  await chmod(executable, 0o755);

  const resources = join(app, "Contents", "Resources");
  const realEngine = join(resources, "dustless-real");
  await rm(realEngine, { force: true });
  await rename(join(resources, "dustless"), realEngine);
  await chmod(realEngine, 0o755);
  await writeFile(join(resources, "dustless"), wrapperEngine(), { mode: 0o755 });

  const signed = run("codesign", ["--force", "--deep", "--sign", "-", app]);
  if (signed.status !== 0) throw new Error(`codesign failed:\n${signed.stderr}`);
  const verified = run("codesign", ["--verify", "--deep", app]);
  if (verified.status !== 0) throw new Error(`codesign verify failed:\n${verified.stderr}`);

  const version = run("plutil", ["-extract", "CFBundleShortVersionString", "raw", info]).stdout.trim();
  return { path: app, executable, version };
}

function wrapperEngine(): string {
  return `#!/bin/bash
set -u
if [ -n "\${DUSTLESS_E2E_LOG:-}" ]; then
  printf '%s\\n' "$*" >> "$DUSTLESS_E2E_LOG"
fi
real="$(cd "$(dirname "$0")" && pwd)/dustless-real"
state_dir="\${DUSTLESS_E2E_STATE:-/tmp}"
fixtures="\${DUSTLESS_E2E_FIXTURES:-}"
intercept="\${DUSTLESS_E2E_INTERCEPT:-}"
case "$intercept:$1" in
  net:net|both:net)
    case "\${2:-}" in
      --print-privilege) cat "$fixtures/net-privilege.json"; exit 0 ;;
      --advanced) cat "$fixtures/net.json"; exit 0 ;;
      --json|"") cat "$fixtures/net.json"; exit 0 ;;
    esac
    op="\${2#--}"
    printf '{"platform":"mac","iface":"en0","gateway":"192.168.1.1","dns":["1.1.1.1","8.8.8.8"],"soloRoute":false,"outcomes":[{"op":"%s","status":"ran","detail":"e2e intercepted","before":null,"after":null}]}' "$op"
    exit 0
    ;;
  awdl:awdl|both:awdl)
    case "\${2:-}" in
      --print-privilege) cat "$fixtures/awdl-privilege.json"; exit 0 ;;
    esac
    current="on"
    [ -f "$state_dir/awdl" ] && current="$(cat "$state_dir/awdl")"
    if [ "\${2:-}" = "--on" ]; then current="on"; printf 'on' > "$state_dir/awdl"; fi
    if [ "\${2:-}" = "--off" ]; then current="off"; printf 'off' > "$state_dir/awdl"; fi
    if [ "\${2:-}" = "--json" ]; then
      cat "$fixtures/awdl.json" | sed "s/\\"state\\":\\"on\\"/\\"state\\":\\"$current\\"/"
      exit 0
    fi
    printf '{"platform":"mac","interface":"awdl0","state":"%s","changed":true,"outcome":{"op":"awdl","status":"ran","detail":"e2e intercepted"}}' "$current"
    exit 0
    ;;
esac
exec "$real" "$@"
`;
}

export class UiApp {
  readonly root: string;
  readonly home: string;
  readonly outside: string;
  readonly prefs: string;
  readonly log: string;
  readonly state: string;
  readonly appPath: string;
  readonly artifactDir: string;
  readonly launchOptions: LaunchOptions;
  private child: ReturnType<typeof spawn> | null = null;
  pid = 0;

  private constructor(root: string, app: TestApp, options: LaunchOptions) {
    this.root = root;
    this.home = join(root, "home");
    this.outside = join(root, "outside");
    this.prefs = join(root, "prefs.plist");
    this.log = join(root, "engine.log");
    this.state = join(root, "state");
    this.appPath = app.path;
    this.launchOptions = options;
    this.artifactDir = join(ARTIFACTS, `${new Date().toISOString().replace(/[:.]/g, "-")}-${options.label}`);
  }

  static async launch(app: TestApp, options: LaunchOptions, seed?: Seed): Promise<UiApp> {
    const root = await mkdtemp(join(tmpdir(), "dustless-ui-"));
    const instance = new UiApp(root, app, options);
    try {
      await instance.prepare();
      await seed?.(instance);
      await instance.start();
      return instance;
    } catch (error) {
      await instance.stop();
      throw error;
    }
  }

  private async prepare() {
    await mkdir(this.home, { recursive: true });
    await mkdir(this.outside, { recursive: true });
    await mkdir(this.state, { recursive: true });
    await mkdir(join(this.home, "Library", "Preferences"), { recursive: true });
    await mkdir(join(this.home, "tmp"), { recursive: true });
    await mkdir(join(this.home, "Applications"), { recursive: true });
    await mkdir(join(this.root, "sudoers"), { recursive: true });
    await mkdir(this.artifactDir, { recursive: true });
    await writeFile(join(this.outside, "canary.txt"), "dustless-ui-canary\n");
    await writeFile(this.prefs, preferencesPlist(this.launchOptions.language ?? "en"));
    await writeFile(join(this.root, "sudoers", "dustless-net"), "");
    await writeFile(join(this.root, "sudoers", "dustless-awdl"), "");
  }

  private env(): Record<string, string> {
    const env: Record<string, string> = {
      HOME: this.home,
      CFFIXED_USER_HOME: this.home,
      TMPDIR: join(this.home, "tmp"),
      XDG_CONFIG_HOME: join(this.home, ".config"),
      DUSTLESS_PREFS_FILE: this.prefs,
      DUSTLESS_SELECTION_DIR: join(this.home, "tmp"),
      DUSTLESS_SUDOERS_DIR: join(this.root, "sudoers"),
      DUSTLESS_E2E_LOG: this.log,
      DUSTLESS_E2E_STATE: this.state,
      DUSTLESS_E2E_FIXTURES: FIXTURES,
      DUSTLESS_UI_TESTING: "1",
      DUSTLESS_APPS_DIRS: join(this.home, "Applications"),
      PATH: process.env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
    };
    if (this.launchOptions.intercepted) {
      env["DUSTLESS_E2E_INTERCEPT"] = this.launchOptions.intercepted;
    }
    return env;
  }

  private async start() {
    await this.writeRules();
    this.child = spawn(this.executable(), [], {
      env: this.env(),
      cwd: this.root,
      stdio: ["ignore", "pipe", "pipe"],
      detached: true,
    });
    this.pid = this.child.pid ?? 0;
    if (!this.pid) throw new Error("failed to launch DustlessE2E");
    this.captureOutput();
    try {
      await this.find("toolbar.scan", 30_000);
    } catch (error) {
      throw new Error(
        `DustlessE2E did not show its window (pid ${this.pid}).\n` +
          `stdout:\n${await this.stdout()}\nengine log:\n${await this.engineLog()}\n${String(error)}`,
      );
    }
  }

  private executable(): string {
    return join(this.appPath, "Contents", "MacOS", APP_NAME);
  }

  private captureOutput() {
    if (!this.child) return;
    const out = this.child.stdout;
    const err = this.child.stderr;
    if (out) out.on("data", (chunk) => append(join(this.root, "app.stdout.log"), chunk));
    if (err) err.on("data", (chunk) => append(join(this.root, "app.stderr.log"), chunk));
  }

  private async writeRules() {
    const config = join(this.home, ".config", "dustless");
    await mkdir(config, { recursive: true });
    const bundled = Bun.YAML.parse(
      await readFile(join(REPO, "src", "core", "default-rules.yaml"), "utf8"),
    ) as Array<{ id?: unknown }>;
    const overrides = bundled
      .map((rule) => rule.id)
      .filter((id): id is string => typeof id === "string" && id.length > 0)
      .map((id) => `- id: ${id}\n  tier: green\n  desc: E2E override\n  paths:\n    all: ["~/.dustless-e2e/noop"]\n`);
    await writeFile(
      join(config, "rules.yaml"),
      [
        ...overrides,
        "- id: e2e.green",
        "  tier: green",
        "  desc: E2E disposable cache",
        "  recoveryLabel: download",
        "  paths:",
        '    all: ["~/.dustless-e2e/green", "~/.dustless-e2e/fail"]',
        "- id: e2e.locked",
        "  tier: yellow",
        "  desc: E2E blocked dependency tree",
        "  paths:",
        '    all: "~/.e2e-node/node_modules"',
        "  requireVerify: git_clean",
        "  minAgeDays: 0",
        "  recoveryLabel: download",
        "",
      ].join("\n"),
    );
  }

  async driver(args: string[], allowFailure = false): Promise<DriverResult> {
    await ensureDriver();
    const result = run(DRIVER_BIN, [...args, "--pid", String(this.pid)]);
    if (result.status === 2) throw new Error(`AX driver usage error: ${result.stderr}`);
    if (result.status === 3) {
      if (allowFailure) return { found: false };
      throw new Error(`AX element not found: ${args.join(" ")}`);
    }
    if (result.status !== 0) throw new Error(`AX driver failed (${result.status}): ${result.stderr}`);
    try {
      return JSON.parse(result.stdout) as DriverResult;
    } catch {
      throw new Error(`AX driver returned non-JSON: ${result.stdout}`);
    }
  }

  async find(identifier: string, timeout = 10_000): Promise<DriverResult> {
    return this.driver(["wait", "--id", identifier, "--timeout", String(timeout / 1000)]);
  }

  async exists(identifier: string): Promise<boolean> {
    const result = await this.driver(["wait", "--id", identifier, "--timeout", "0"], true);
    return result.found !== false;
  }

  async press(identifier: string, timeout = 10_000): Promise<void> {
    await this.driver(["press", "--id", identifier, "--timeout", String(timeout / 1000)]);
  }

  async click(identifier: string, timeout = 10_000): Promise<void> {
    await this.driver(["click", "--id", identifier, "--timeout", String(timeout / 1000)]);
  }

  async pressMenuItem(item: string): Promise<void> {
    await this.driver(["menu", "--item", item]);
  }

  async openMenuBar(): Promise<void> {
    await this.driver(["menubar"]);
  }

  async waitGone(identifier: string, timeout = 10_000): Promise<void> {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      if (!(await this.exists(identifier))) return;
      await Bun.sleep(100);
    }
    throw new Error(`element still present: ${identifier}`);
  }

  async screenshot(name: string): Promise<string> {
    const ids = await this.driver(["window-id"]);
    const id = Array.isArray(ids) ? (ids as number[])[0] : undefined;
    if (!id) throw new Error("app window not found for screenshot");
    const path = join(this.artifactDir, `${name}.png`);
    const result = run("screencapture", ["-x", "-l", String(id), path]);
    if (result.status !== 0) throw new Error(`screencapture failed: ${result.stderr}`);
    return path;
  }

  async dump(name: string): Promise<void> {
    const path = join(this.artifactDir, `${name}-ax.json`);
    await this.driver(["dump", "--out", path]).catch(() => {});
  }

  async engineLog(): Promise<string> {
    return readFile(this.log, "utf8").catch(() => "");
  }

  async stdout(): Promise<string> {
    return readFile(join(this.root, "app.stdout.log"), "utf8").catch(() => "");
  }

  async waitForEngineLog(predicate: (line: string) => boolean, timeout = 10_000): Promise<string> {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      const lines = (await this.engineLog()).split("\n").filter(Boolean);
      const match = lines.find(predicate);
      if (match) return match;
      await Bun.sleep(100);
    }
    throw new Error(`engine invocation not observed. log:\n${await this.engineLog()}`);
  }

  async stop(clean = true) {
    if (this.pid) {
      terminate(this.pid, "SIGTERM");
      const deadline = Date.now() + 5_000;
      while (Date.now() < deadline) {
        if (!isAlive(this.pid)) break;
        await Bun.sleep(100);
      }
      if (isAlive(this.pid)) terminate(this.pid, "SIGKILL");
    }
    if (clean) await rm(this.root, { recursive: true, force: true });
  }
}

function preferencesPlist(language: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>dustless.language</key><string>${language}</string>
</dict>
</plist>
`;
}

function append(path: string, chunk: Buffer) {
  appendFile(path, chunk).catch(() => {});
}

function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function terminate(pid: number, signal: NodeJS.Signals) {
  try {
    process.kill(-pid, signal);
  } catch {}
  try {
    process.kill(pid, signal);
  } catch {}
}

export function plistValue(path: string, key: string): string {
  const result = run("plutil", ["-convert", "json", "-o", "-", path]);
  if (result.status !== 0) throw new Error(`plutil failed: ${result.stderr}`);
  const value = (JSON.parse(result.stdout) as Record<string, unknown>)[key];
  if (value === undefined) throw new Error(`plist key not found: ${key}`);
  return String(value);
}

