import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readdir, readFile, rm, stat, utimes, writeFile } from "node:fs/promises";
import { connect, createServer } from "node:net";
import { networkInterfaces } from "node:os";
import { isAbsolute, join, relative, resolve } from "node:path";

export const REPO = resolve(import.meta.dir, "..", "..");
const MB = 1024 * 1024;
const DAY = 86_400_000;

export type Sandbox = {
  root: string;
  home: string;
  planted: string[];
  fingerprint: () => Promise<string>;
  dispose: () => Promise<void>;
};

export type UiServer = {
  url: string;
  port: number;
  proc: ChildProcess;
  stderr: () => string;
  stop: () => Promise<void>;
};

export function assertInsideSandbox(target: string, root: string): string {
  const full = resolve(target);
  const base = resolve(root);
  const rel = relative(base, full);
  if (!rel || isAbsolute(rel) || rel.startsWith("..")) {
    throw new Error(`REFUSING: ${full} is not strictly inside the sandbox ${base}`);
  }
  return full;
}

export async function makeSandbox(): Promise<Sandbox> {
  const root = await mkdtemp(join(process.env["TMPDIR"] ?? "/tmp", "dustless-ui-"));
  const home = join(root, "home");
  await mkdir(join(home, ".npm/_cacache"), { recursive: true });
  await mkdir(join(home, ".bun/install/cache"), { recursive: true });
  await mkdir(join(home, "proj/build"), { recursive: true });
  await mkdir(join(home, "proj/gradle/wrapper"), { recursive: true });
  await mkdir(join(home, ".gradle/caches/8.14"), { recursive: true });

  const plant = async (rel: string, bytes: number, ageDays: number): Promise<string> => {
    const full = join(home, rel);
    await writeFile(full, Buffer.alloc(bytes, 0x41));
    const stamp = (Date.now() - ageDays * DAY) / 1000;
    await utimes(full, stamp, stamp);
    return full;
  };

  const planted = [
    await plant(".npm/_cacache/blob.bin", 5 * MB, 40),
    await plant(".bun/install/cache/pkg.bin", 3 * MB, 40),
    await plant("proj/build/out.bin", 2 * MB, 2),
    await plant(".gradle/caches/8.14/cache.bin", 2 * MB, 45),
  ];
  await writeFile(
    join(home, "proj/gradle/wrapper/gradle-wrapper.properties"),
    "distributionUrl=https\\://services.gradle.org/distributions/gradle-8.14-bin.zip\n",
  );
  await writeFile(join(home, "proj/gradlew"), "#!/bin/sh\n");

  const fingerprint = async (): Promise<string> => {
    const lines: string[] = [];
    const walk = async (dir: string): Promise<void> => {
      for (const entry of await readdir(dir, { withFileTypes: true }).catch(() => [])) {
        const full = join(dir, entry.name);
        if (entry.isDirectory()) {
          lines.push(`d ${relative(root, full)}`);
          await walk(full);
        } else {
          const meta = await stat(full);
          const hash = createHash("sha256").update(await readFile(full)).digest("hex");
          lines.push(`f ${relative(root, full)} ${meta.size} ${hash}`);
        }
      }
    };
    await walk(root);
    const digest = createHash("sha256");
    for (const line of lines.sort()) digest.update(line);
    return digest.digest("hex");
  };

  return {
    root,
    home,
    planted,
    fingerprint,
    dispose: async () => {
      await rm(root, { recursive: true, force: true });
    },
  };
}

export async function freePort(): Promise<number> {
  return await new Promise<number>((done, fail) => {
    const probe = createServer();
    probe.once("error", fail);
    probe.listen(0, "127.0.0.1", () => {
      const address = probe.address();
      probe.close(() => done(typeof address === "object" && address ? address.port : 0));
    });
  });
}

export async function startUiServer(sandbox: Sandbox): Promise<UiServer> {
  const port = await freePort();
  const proc = spawn(process.execPath, [join(REPO, "src", "cli.ts"), "ui", "--port", String(port), "--no-open"], {
    cwd: REPO,
    env: {
      ...process.env,
      HOME: sandbox.home,
      XDG_CONFIG_HOME: join(sandbox.home, ".config"),
      TMPDIR: sandbox.root,
      NO_COLOR: "1",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let err = "";
  proc.stderr?.on("data", (chunk) => (err += String(chunk)));
  proc.stdout?.resume();

  const url = `http://127.0.0.1:${port}`;
  const deadline = Date.now() + 30_000;
  for (;;) {
    if (proc.exitCode !== null) throw new Error(`ui server exited early (${proc.exitCode}): ${err}`);
    const ready = await fetch(`${url}/index.html`, { signal: AbortSignal.timeout(1500) }).then(
      (res) => res.ok,
      () => false,
    );
    if (ready) break;
    if (Date.now() > deadline) throw new Error(`ui server never became ready: ${err}`);
    await Bun.sleep(100);
  }

  return {
    url,
    port,
    proc,
    stderr: () => err,
    stop: async () => {
      if (proc.exitCode !== null) return;
      proc.kill("SIGTERM");
      await new Promise<void>((done) => {
        const timer = setTimeout(() => {
          proc.kill("SIGKILL");
          done();
        }, 4000);
        proc.once("exit", () => {
          clearTimeout(timer);
          done();
        });
      });
    },
  };
}

export function listeners(port: number): string[] {
  const out = spawnSync("lsof", ["-nP", "-iTCP:" + String(port), "-sTCP:LISTEN", "-F", "n"], { encoding: "utf8" });
  if (out.error) throw new Error(`lsof is required for the bind check: ${out.error.message}`);
  return (out.stdout ?? "")
    .split("\n")
    .filter((line) => line.startsWith("n"))
    .map((line) => line.slice(1).trim())
    .filter(Boolean);
}

export function nonLoopbackAddress(): string | null {
  for (const addresses of Object.values(networkInterfaces())) {
    for (const entry of addresses ?? []) {
      if (entry.family === "IPv4" && !entry.internal) return entry.address;
    }
  }
  return null;
}

export async function connectFrom(host: string, port: number): Promise<string> {
  return await new Promise<string>((done) => {
    const socket = connect({ host, port });
    const finish = (result: string): void => {
      socket.destroy();
      done(result);
    };
    socket.setTimeout(3000);
    socket.once("connect", () => finish("accepted"));
    socket.once("timeout", () => finish("timed out"));
    socket.once("error", (error: NodeJS.ErrnoException) => finish(error.code ?? "error"));
  });
}

export async function sizeOf(path: string): Promise<number | null> {
  return await stat(path).then(
    (meta) => meta.size,
    () => null,
  );
}