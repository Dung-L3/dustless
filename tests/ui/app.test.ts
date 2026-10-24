import { afterAll, describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { access, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  buildTestApp,
  driverTrusted,
  plistValue,
  removeTestDomainPrefs,
  UiApp,
  uiTestingEnabled,
  type LaunchOptions,
  type Seed,
  type TestApp,
} from "./harness.ts";

if (process.env["DUSTLESS_UI"] === "1" && process.platform !== "darwin") {
  throw new Error("DUSTLESS_UI=1 requires macOS");
}
const enabled = uiTestingEnabled();
const trusted = enabled ? await driverTrusted() : false;
if (enabled && !trusted) {
  throw new Error(
    "DUSTLESS_UI=1 requires macOS Accessibility trust for the test runner; " +
      "grant it in System Settings → Privacy & Security → Accessibility, then rerun",
  );
}
const testApp: TestApp | null = enabled && trusted ? await buildTestApp() : null;

afterAll(async () => {
  if (enabled) await removeTestDomainPrefs();
});

async function exists(path: string): Promise<boolean> {
  return access(path).then(() => true, () => false);
}

async function withApp(
  label: string,
  options: Omit<LaunchOptions, "label">,
  run: (app: UiApp) => Promise<void>,
  seed?: Seed,
) {
  const app = await UiApp.launch(testApp!, { ...options, label }, seed);
  try {
    await run(app);
  } catch (error) {
    const screenshot = await app.screenshot(`${label}-failure`).catch(() => "");
    await app.dump(`${label}-failure`).catch(() => {});
    throw new Error(
      `${String(error)}\nartifacts: ${app.artifactDir}\nscreenshot: ${screenshot}\n` +
        `engine log:\n${await app.engineLog()}`,
    );
  } finally {
    await app.stop();
  }
}

async function seedCleanup(app: UiApp) {
  await mkdir(join(app.home, ".dustless-e2e", "green"), { recursive: true });
  await writeFile(join(app.home, ".dustless-e2e", "green", "old.bin"), "green fixture\n");
  await mkdir(join(app.home, ".dustless-e2e", "fail"), { recursive: true });
  await writeFile(join(app.home, ".dustless-e2e", "fail", "keep.bin"), "fail fixture\n");
  await mkdir(join(app.home, ".e2e-node", "node_modules"), { recursive: true });
  await writeFile(join(app.home, ".e2e-node", "node_modules", "stale.js"), "stale dependency\n");
}

async function seedStorage(app: UiApp) {
  const bundle = join(app.home, "Applications", "E2E Toy.app");
  await mkdir(join(bundle, "Contents", "MacOS"), { recursive: true });
  await writeFile(
    join(bundle, "Contents", "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.dustless.e2e.toy</string>
<key>CFBundleName</key><string>E2E Toy</string>
<key>CFBundleDisplayName</key><string>E2E Toy</string>
</dict></plist>`,
  );
  await writeFile(join(bundle, "Contents", "MacOS", "E2EToy"), "fixture\n");
  await mkdir(join(app.home, "Library", "Caches", "dev.dustless.e2e.toy"), { recursive: true });
  await writeFile(join(app.home, "Library", "Caches", "dev.dustless.e2e.toy", "cache.bin"), "cache fixture\n");
}

async function seedLargeFile(app: UiApp) {
  const path = join(app.home, "Downloads", "e2e-large.bin");
  await mkdir(join(app.home, "Downloads"), { recursive: true });
  await writeFile(path, "");
  const truncate = Bun.spawnSync(["truncate", "-s", String(210 * 1024 * 1024), path], { stderr: "pipe" });
  if (truncate.exitCode !== 0) throw new Error(`truncate failed: ${truncate.stderr.toString()}`);
}

async function startMemoryFixture() {
  const root = await mkdtemp(join(tmpdir(), "e2e-mem-"));
  const source = join(root, "fixture.c");
  const binary = join(root, "E2EDocker");
  await writeFile(
    source,
    `#include <stdlib.h>
#include <unistd.h>
int main(void) {
  size_t n = 300UL * 1024UL * 1024UL;
  volatile char *p = malloc(n);
  if (!p) return 1;
  for (size_t i = 0; i < n; i += 4096) p[i] = 1;
  sleep(300);
  return 0;
}`,
  );
  const built = Bun.spawnSync(["clang", "-O0", "-o", binary, source], { stderr: "pipe" });
  if (built.exitCode !== 0) {
    await rm(root, { recursive: true, force: true });
    throw new Error(`clang failed: ${built.stderr.toString()}`);
  }
  const child = spawn(binary, [], { stdio: "ignore" });
  const canary = spawn(binary, [], { stdio: "ignore" });
  return { child, canary, root, binary };
}

describe.skipIf(!testApp)("Dustless macOS UI", () => {
  test("launches the real app and renders the overview", async () => {
    await withApp("launch", {}, async (app) => {
      expect(app.pid).toBeGreaterThan(0);
      expect(app.home).not.toBe(process.env["HOME"]);
      expect(await app.exists("sidebar.module.overview")).toBe(true);
      expect(await app.exists("overview.header")).toBe(true);
      expect(await app.exists("overview.tier.safe")).toBe(true);
      expect(await app.exists("overview.scan")).toBe(true);
      expect(await app.exists("toolbar.scan")).toBe(true);
      const hero = await app.find("overview.tier.safe");
      expect(String(hero.description ?? "")).toContain("Safe");
      const screenshot = await app.screenshot("launch");
      expect(await exists(screenshot)).toBe(true);
    });
  });

  test("navigates modules through the sidebar and Go menu", async () => {
    await withApp("navigation", {}, async (app) => {
      await app.click("sidebar.module.storage");
      await app.find("storage.header");
      await app.pressMenuItem("Memory");
      await app.find("memory.header");
      await app.pressMenuItem("Network");
      await app.find("network.header");
      await app.pressMenuItem("Overview");
      await app.find("overview.header");
      await app.pressMenuItem("Storage");
      await app.find("storage.header");
      await app.click("sidebar.tier.safe");
      await app.find("cleanup.rescan");
      await app.find("cleanup.search");
    });
  });

  test("opens the menu bar popover and routes to a module", async () => {
    await withApp("menubar", {}, async (app) => {
      await app.openMenuBar();
      await app.find("menubar.open");
      expect(await app.exists("menubar.module.storage")).toBe(true);
      expect(await app.exists("menubar.status")).toBe(true);
      expect(await app.exists("menubar.busy")).toBe(false);
      await app.screenshot("menubar-open");
      await app.press("menubar.module.storage");
      await app.find("storage.header");
    });
  });

  test("runs a quick clean from the menu bar popover", async () => {
    await withApp(
      "menubar-quickclean",
      {},
      async (app) => {
        const green = join(app.home, ".dustless-e2e", "green");
        const fail = join(app.home, ".dustless-e2e", "fail");
        await app.openMenuBar();
        await app.find("menubar.quickClean", 20_000);
        expect(await app.exists("menubar.result")).toBe(false);
        await app.screenshot("menubar-quickclean");
        await app.press("menubar.quickClean");
        await app.find("confirm.delete");
        await app.press("confirm.cancel");
        await app.waitGone("confirm.cancel");
        expect(await exists(green)).toBe(true);
        expect(await exists(fail)).toBe(true);
        expect(await app.engineLog()).not.toContain("apply --json");

        await app.openMenuBar();
        await app.find("menubar.review");
        await app.press("menubar.review");
        await app.find("confirm.delete");
        await app.press("confirm.delete");
        await app.find("cleanup.result.counts", 30_000);
        const counts = await app.find("cleanup.result.counts");
        expect(String(counts.value ?? "")).toBe("2 deleted · 1 skipped · 0 failed");
        expect(await exists(green)).toBe(false);
        expect(await exists(fail)).toBe(false);
        await app.screenshot("menubar-quickclean-result");
      },
      seedCleanup,
    );
  });

  test("persists a setting in the isolated preferences file", async () => {
    await withApp("settings", { language: "en" }, async (app) => {
      await app.press("toolbar.settings");
      await app.find("settings.language");
      expect(await app.exists("settings.showInDock")).toBe(true);
      await app.press("settings.showInDock");
      await Bun.sleep(250);
      expect(["false", "0"]).toContain(plistValue(app.prefs, "dustless.showInDock"));
      await app.press("settings.showInDock");
      await Bun.sleep(250);
      expect(["true", "1"]).toContain(plistValue(app.prefs, "dustless.showInDock"));
      await app.screenshot("settings");
    });
  });

  test("reads the selected language from the isolated preferences file", async () => {
    await withApp("language-vi", { language: "vi" }, async (app) => {
      const header = await app.find("overview.header");
      expect(String(header.value ?? "")).toBe("Tổng quan");
    });
  });

  test("runs network and AirDrop actions through the injected engine", async () => {
    await withApp("network", { intercepted: "both" }, async (app) => {
      await app.click("sidebar.module.network");
      await app.find("network.header");
      await app.find("network.run.reset-dns");
      expect(await app.exists("network.remembered")).toBe(true);
      await app.waitForEngineLog((line) => line.includes("net --advanced"));
      await app.press("network.run.reset-dns");
      await app.find("network.outcome.reset-dns", 20_000);
      await app.waitForEngineLog((line) => line.includes("net --reset-dns"));
      const outcome = await app.find("network.outcome.reset-dns");
      expect(String(outcome.description ?? outcome.help ?? "")).toContain("e2e intercepted");

      await app.find("network.awdl.state");
      const initial = await app.find("network.awdl.state");
      expect(String(initial.value ?? "").toLowerCase()).toContain("on");
      await app.press("network.awdl.toggle");
      await app.waitForEngineLog((line) => line.includes("awdl --off --json"));
      const off = await app.find("network.awdl.state");
      expect(String(off.value ?? "").toLowerCase()).toContain("off");
      expect((await readFile(join(app.state, "awdl"), "utf8")).trim()).toBe("off");
      await app.screenshot("network");
    });
  });

  test("uninstalls a sandboxed app and moves a sandboxed large file to Trash", async () => {
    await withApp(
      "storage",
      {},
      async (app) => {
        const bundle = join(app.home, "Applications", "E2E Toy.app");
        const cache = join(app.home, "Library", "Caches", "dev.dustless.e2e.toy");
        const large = join(app.home, "Downloads", "e2e-large.bin");
        const trash = join(app.home, ".Trash", "e2e-large.bin");
        await seedLargeFile(app);
        await app.click("sidebar.module.storage");
        await app.find("storage.header");
        await app.find("storage.app.uninstall.dev.dustless.e2e.toy");
        await app.press("storage.app.uninstall.dev.dustless.e2e.toy");
        await app.find("storage.uninstall.cancel");
        await app.press("storage.uninstall.cancel");
        await app.waitGone("storage.uninstall.cancel");
        expect(await exists(bundle)).toBe(true);
        expect(await exists(cache)).toBe(true);
        await app.press("storage.app.uninstall.dev.dustless.e2e.toy");
        await app.find("storage.uninstall.confirm");
        await app.press("storage.uninstall.confirm");
        await app.find("storage.result.close", 20_000);
        expect(await exists(bundle)).toBe(false);
        expect(await exists(cache)).toBe(false);
        await app.press("storage.result.close");
        await app.waitGone("storage.result.close");

        await app.click("storage.advanced");
        await app.find(`storage.file.trash.${large}`, 20_000);
        await app.press(`storage.file.trash.${large}`);
        await app.find("storage.trash.cancel");
        await app.press("storage.trash.cancel");
        await app.waitGone("storage.trash.cancel");
        expect(await exists(large)).toBe(true);
        await app.press(`storage.file.trash.${large}`);
        await app.find("storage.trash.confirm");
        await app.press("storage.trash.confirm");
        await app.find("storage.result.close", 20_000);
        expect(await exists(large)).toBe(false);
        expect(await exists(trash)).toBe(true);
        await app.screenshot("storage");
      },
      seedStorage,
    );
  });

  test("cancels cleanup, then deletes a selected fixture and reports a real failure", async () => {
    await withApp(
      "cleanup",
      {},
      async (app) => {
        const green = join(app.home, ".dustless-e2e", "green");
        const fail = join(app.home, ".dustless-e2e", "fail");
        const blocked = join(app.home, ".e2e-node", "node_modules");
        await app.click("sidebar.tier.safe");
        await app.find("cleanup.selectAll");
        await app.press("cleanup.selectAll");
        const selected = await app.find("cleanup.selected");
        expect(String(selected.value ?? "")).toMatch(/^2 selected\b/);
        await app.press("cleanup.review");
        await app.find("confirm.cancel");
        await app.screenshot("cleanup-confirm");
        await app.press("confirm.cancel");
        await app.waitGone("confirm.cancel");
        expect(await exists(green)).toBe(true);
        expect(await exists(fail)).toBe(true);
        await app.press("cleanup.selectNone");

        await app.click("sidebar.tier.locked");
        await app.find(`cleanup.locked.${blocked}`);
        const review = await app.find("cleanup.review");
        expect(review.enabled).toBe(false);

        await app.click("sidebar.tier.safe");
        await app.find("cleanup.selectAll");
        await app.press("cleanup.selectAll");
        const selectedAgain = await app.find("cleanup.selected");
        expect(String(selectedAgain.value ?? "")).toMatch(/^2 selected\b/);
        const immutable = join(fail, "keep.bin");
        const flag = Bun.spawnSync(["chflags", "uchg", immutable]);
        if (flag.exitCode !== 0) throw new Error(`chflags failed: ${flag.stderr.toString()}`);
        try {
          await app.press("cleanup.review");
          await app.find("confirm.delete");
          await app.press("confirm.delete");
          await app.find("cleanup.result.counts", 30_000);
          const counts = await app.find("cleanup.result.counts");
          expect(String(counts.value ?? "")).toBe("1 deleted · 1 skipped · 1 failed");
          expect(await exists(green)).toBe(false);
          expect(await exists(fail)).toBe(true);
          expect(await exists(blocked)).toBe(true);
          await app.screenshot("cleanup-result");
        } finally {
          Bun.spawnSync(["chflags", "nouchg", immutable]);
        }
        await rm(fail, { recursive: true, force: true });
      },
      seedCleanup,
    );
  });

  test("stops only the sandboxed fixture process", async () => {
    const fixture = await startMemoryFixture();
    try {
      await Bun.sleep(750);
      await withApp("memory", {}, async (app) => {
        expect(fixture.child.pid).toBeGreaterThan(0);
        expect(fixture.canary.pid).toBeGreaterThan(0);
        await app.click("sidebar.module.memory");
        await app.find("memory.header");
        await app.click("memory.filter.container");
        await app.find("memory.summary");
        await app.find(`memory.group.${fixture.binary}`, 20_000);
        await app.find(`memory.stop.${fixture.child.pid}`, 20_000);
        await app.press(`memory.stop.${fixture.child.pid}`);
        const deadline = Date.now() + 10_000;
        while (processAlive(fixture.child.pid!) && Date.now() < deadline) await Bun.sleep(100);
        expect(processAlive(fixture.child.pid!)).toBe(false);
        expect(processAlive(fixture.canary.pid!)).toBe(true);
        await app.waitGone(`memory.stop.${fixture.child.pid}`, 10_000);
        await app.screenshot("memory");
      });
    } finally {
      if (fixture.child.pid && processAlive(fixture.child.pid)) fixture.child.kill("SIGKILL");
      if (fixture.canary.pid && processAlive(fixture.canary.pid)) fixture.canary.kill("SIGKILL");
      await rm(fixture.root, { recursive: true, force: true });
    }
  });
});

function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}
