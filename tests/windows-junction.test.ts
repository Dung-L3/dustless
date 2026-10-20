import { afterAll, describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const probe = resolve(import.meta.dir, "fixtures", "windows-junction-probe.ts");
const roots: string[] = [];

afterAll(async () => {
  for (const root of roots) await rm(root, { recursive: true, force: true });
});

async function runProbe(scenario: string): Promise<void> {
  const home = await mkdtemp(join(tmpdir(), `dustless-junction-${scenario}-`));
  roots.push(home);
  const env = {
    ...process.env,
    HOME: home,
    USERPROFILE: home,
    XDG_CONFIG_HOME: join(home, ".config"),
    TMPDIR: home,
    TMP: home,
    TEMP: home,
    NO_COLOR: "1",
  };
  const result = await new Promise<{ code: number | null; stdout: string; stderr: string }>((done) => {
    const child = spawn(process.execPath, [probe, scenario], { env, cwd: resolve(import.meta.dir, "..") });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      stderr += "\nTIMEOUT";
      child.kill("SIGKILL");
    }, 30_000);
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("error", (err) => {
      clearTimeout(timer);
      done({ code: -1, stdout, stderr: `${stderr}\n${err.message}` });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      done({ code, stdout, stderr });
    });
  });
  if (result.code !== 0) {
    throw new Error(`junction probe ${scenario} failed (${result.code})\n${result.stderr}\n${result.stdout}`);
  }
  expect(result.stdout).toContain("ok");
}

describe.skipIf(process.platform !== "win32")("Windows junction boundaries (Windows-only)", () => {
  test("recursive apply of a junction leaf leaves the target intact", async () => {
    await runProbe("leaf");
  });

  test("a path through a junction into a red directory is refused as red", async () => {
    await runProbe("red");
  });

  test("a path through a clean junction is still refused", async () => {
    await runProbe("through");
  });

  test("moveToTrash moves the junction leaf and leaves the target intact", async () => {
    await runProbe("trash");
  });

  test("findLargeFiles does not walk through a junction", async () => {
    await runProbe("walk");
  });
});
