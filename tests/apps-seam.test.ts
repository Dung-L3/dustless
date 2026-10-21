import { afterAll, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { listApps, uninstall } from "../src/core/apps/index.ts";
import { BINARY, exec } from "./e2e/harness.ts";

const created: string[] = [];

const exists = async (path: string): Promise<boolean> => await stat(path).then(() => true, () => false);

async function sandbox(label: string): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), `dustless-apps-seam-${label}-`));
  created.push(dir);
  return dir;
}

async function makeApp(appPath: string, bundleId: string, name: string): Promise<string> {
  await mkdir(join(appPath, "Contents", "MacOS"), { recursive: true });
  await writeFile(
    join(appPath, "Contents", "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>${bundleId}</string>
  <key>CFBundleName</key>
  <string>${name}</string>
</dict>
</plist>`,
  );
  await writeFile(join(appPath, "Contents", "MacOS", name), "#!/bin/sh\n");
  return appPath;
}

async function binaryContains(path: string, needle: string): Promise<boolean> {
  const file = Bun.file(path);
  const target = new TextEncoder().encode(needle);
  const chunk = new Uint8Array(1024 * 1024);
  let carry = new Uint8Array(0);
  let offset = 0;
  while (offset < file.size) {
    const bytes = new Uint8Array(await file.slice(offset, offset + chunk.length).arrayBuffer());
    const window = new Uint8Array(carry.length + bytes.length);
    window.set(carry, 0);
    window.set(bytes, carry.length);
    outer: for (let at = 0; at + target.length <= window.length; at++) {
      for (let index = 0; index < target.length; index++) {
        if (window[at + index] !== target[index]) continue outer;
      }
      return true;
    }
    carry = window.slice(Math.max(0, window.length - target.length));
    offset += bytes.length;
  }
  return false;
}

afterAll(async () => {
  for (const dir of created) await rm(dir, { recursive: true, force: true });
});

describe("the app install test seam can only narrow the uninstall scope", () => {
  test("the library refuses an app outside the default app directories even when a seam lists it", async () => {
    const home = await sandbox("library");
    const tools = join(home, "tools");
    const appPath = await makeApp(join(tools, "Evil.app"), "com.example.evil", "Evil");

    const report = await uninstall({
      home,
      appPath,
      relatedPaths: [],
      confirm: true,
      appDirs: [tools],
    });

    expect(report.summary.trashed).toBe(0);
    expect(report.summary.purged).toBe(0);
    expect(report.summary.failed).toBe(1);
    expect(report.outcomes[0]?.detail).toMatch(/not in allowed app directories|denied/);
    expect(await exists(appPath)).toBe(true);
  });

  test("the inventory does not list an app outside the default app directories when a seam asks for it", async () => {
    const home = await sandbox("inventory");
    const tools = join(home, "tools");
    await makeApp(join(tools, "Evil.app"), "com.example.evil", "Evil");
    await makeApp(join(home, "Applications", "Nice.app"), "com.example.nice", "Nice");

    const seammed = await listApps({ home, appDirs: [tools] });
    expect(seammed.map((app) => app.bundleId)).toEqual([]);

    const defaults = await listApps({ home });
    expect(defaults.some((app) => app.bundleId === "com.example.evil")).toBe(false);
    expect(defaults.some((app) => app.bundleId === "com.example.nice")).toBe(true);
  });

  test("the shipped binary cannot uninstall an app outside the default app directories", async () => {
    const home = await sandbox("binary");
    const tools = join(home, "tools");
    const appPath = await makeApp(join(tools, "Evil.app"), "com.example.evil", "Evil");

    const run = await exec(
      ["apps", "--uninstall", appPath, "--confirm", "--json"],
      {
        HOME: home,
        USERPROFILE: home,
        XDG_CONFIG_HOME: join(home, ".config"),
        DUSTLESS_UI_TESTING: "1",
        DUSTLESS_APPS_DIRS: tools,
        PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
      },
      "/",
    );

    expect(run.code).toBe(1);
    expect(run.stdout).toContain("app not found in inventory");
    expect(await exists(appPath)).toBe(true);
    expect(await exists(join(appPath, "Contents", "Info.plist"))).toBe(true);
  });

  test("the shipped binary does not carry the seam variable that used to widen the scope", async () => {
    expect(await binaryContains(BINARY, "DUSTLESS_APPS_DIRS")).toBe(false);
  });

  test("the shipped binary still refuses the app without the seam too", async () => {
    const home = await sandbox("no-seam");
    const tools = join(home, "tools");
    const appPath = await makeApp(join(tools, "Evil.app"), "com.example.evil", "Evil");

    const run = await exec(
      ["apps", "--uninstall", appPath, "--confirm", "--json"],
      {
        HOME: home,
        USERPROFILE: home,
        XDG_CONFIG_HOME: join(home, ".config"),
        PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
      },
      "/",
    );

    expect(run.code).toBe(1);
    expect(run.stdout).toContain("app not found in inventory");
    expect(await exists(appPath)).toBe(true);
  });
});
