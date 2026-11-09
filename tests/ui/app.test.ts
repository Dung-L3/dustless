import { afterAll, describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { access, chmod, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
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

async function startRunningAppFixture(destination: string, bundleId: string, name: string) {
  await mkdir(join(destination, "Contents", "MacOS"), { recursive: true });
  await writeFile(
    join(destination, "Contents", "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${bundleId}</string>
<key>CFBundleName</key><string>${name}</string>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>`,
  );
  const source = join(destination, "fixture.m");
  await writeFile(
    source,
    `#import <Cocoa/Cocoa.h>
int main(void) {
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 220)
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [window makeKeyAndOrderFront:nil];
    [app run];
  }
  return 0;
}`,
  );
  const binary = join(destination, "Contents", "MacOS", "Fixture");
  const built = Bun.spawnSync(["clang", "-framework", "Cocoa", "-o", binary, source]);
  if (built.exitCode !== 0) throw new Error(`fixture build failed: ${built.stderr.toString()}`);
  const opened = Bun.spawnSync(["open", "-a", destination]);
  if (opened.exitCode !== 0) throw new Error(`fixture open failed: ${opened.stderr.toString()}`);
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const found = Bun.spawnSync(["pgrep", "-f", binary]);
    const pid = Number((found.stdout?.toString() ?? "").trim().split("\n")[0]);
    if (Number.isInteger(pid) && pid > 0) {
      return { appPath: destination, bundlePath: await realpath(destination), pid };
    }
    await Bun.sleep(100);
  }
  throw new Error("running app fixture did not start");
}

async function startQuitFixture() {
  const root = await mkdtemp(join(tmpdir(), "e2e-quit-"));
  const app = join(root, "E2E Quit Fixture.app");
  const macos = join(app, "Contents", "MacOS");
  await mkdir(macos, { recursive: true });
  await writeFile(
    join(app, "Contents", "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.dustless.e2e.quitfixture</string>
<key>CFBundleName</key><string>E2E Quit Fixture</string>
<key>CFBundleDisplayName</key><string>E2E Quit Fixture</string>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>`,
  );
  const source = join(root, "fixture.m");
  await writeFile(
    source,
    `#import <Cocoa/Cocoa.h>
int main(void) {
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 220)
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [window makeKeyAndOrderFront:nil];
    [app run];
  }
  return 0;
}`,
  );
  const binary = join(macos, "Fixture");
  const built = Bun.spawnSync(["clang", "-framework", "Cocoa", "-o", binary, source], { stderr: "pipe" });
  if (built.exitCode !== 0) {
    await rm(root, { recursive: true, force: true });
    throw new Error(`fixture build failed: ${built.stderr.toString()}`);
  }
  const opened = Bun.spawnSync(["open", "-a", app], { stderr: "pipe" });
  if (opened.exitCode !== 0) {
    await rm(root, { recursive: true, force: true });
    throw new Error(`fixture open failed: ${opened.stderr.toString()}`);
  }
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const found = Bun.spawnSync(["pgrep", "-f", binary]);
    const output = found.stdout?.toString() ?? "";
    const pid = Number(output.trim().split("\n")[0]);
    if (Number.isInteger(pid) && pid > 0) {
      return { root, app, bundlePath: await realpath(app), pid };
    }
    await Bun.sleep(100);
  }
  await rm(root, { recursive: true, force: true });
  throw new Error("quit fixture did not start");
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
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    if (child.pid && canary.pid && processAlive(child.pid) && processAlive(canary.pid)) {
      return { child, canary, root, binary };
    }
    await Bun.sleep(50);
  }
  if (child.pid) child.kill("SIGKILL");
  if (canary.pid) canary.kill("SIGKILL");
  await rm(root, { recursive: true, force: true });
  throw new Error(
    `memory fixture did not reach a running state (child ${child.pid ?? "-"}, canary ${canary.pid ?? "-"})`,
  );
}

describe.skipIf(!testApp)("Dustless macOS UI", () => {
  test("launches the real app and renders the overview", async () => {
    await withApp("launch", {}, async (app) => {
      expect(app.pid).toBeGreaterThan(0);
      expect(app.home).not.toBe(process.env["HOME"]);
      expect(await app.exists("sidebar.module.overview")).toBe(true);
      expect(await app.exists("overview.header")).toBe(true);
      expect(await app.exists("overview.findings")).toBe(true);
      expect(
      (await app.exists("overview.scan")) || (await app.exists("overview.pick")),
    ).toBe(true);
      expect(await app.exists("toolbar.scan")).toBe(true);
      const hero = await app.find("overview.hero");
      expect(String(hero.value ?? "")).toContain("Reclaimable");
      const screenshot = await app.screenshot("launch");
      expect(await exists(screenshot)).toBe(true);
    });
  });

  test("navigates modules through the sidebar and Go menu", async () => {
    await withApp("navigation", {}, async (app) => {
      await app.pressMenuItem("Storage");
      await app.find("storage.header");
      await app.pressMenuItem("Memory");
      await app.find("memory.header");
      await app.pressMenuItem("Network");
      await app.find("network.header");
      await app.pressMenuItem("Overview");
      await app.find("overview.header");
      await app.pressMenuItem("Storage");
      await app.find("storage.header");
      await app.click("sidebar.module.memory");
      await app.find("memory.header");
      await app.click("sidebar.module.network");
      await app.find("network.header");
      await app.click("sidebar.module.overview");
      await app.find("overview.header");
      await app.click("sidebar.module.cleanup");
      await app.find("cleanup.title");
      await app.click("cleanup.tier.safe");
      await app.find("cleanup.rescan");
      await app.find("cleanup.search");
    });
  });

  test("opens the menu bar popover and routes to a module", async () => {
    await withApp("menubar", {}, async (app) => {
      await app.openMenuBar();
      await app.find("menubar.open");
      expect(await app.exists("menubar.module.storage")).toBe(true);
      expect(await app.exists("menubar.summary")).toBe(true);
      expect(await app.exists("menubar.busy")).toBe(false);
      await app.screenshot("menubar-open");
      await app.press("menubar.module.storage");
      await app.find("storage.header");
    });
  });

  test("reopens the main window after it is closed and released", async () => {
    await withApp("window-reopen", {}, async (app) => {
      await app.closeWindow();
      expect(await app.windowCount()).toBe(0);
      await Bun.sleep(30_000);
      await app.openMenuBar();
      await app.find("menubar.status");
      await app.press("menubar.open");
      await app.find("overview.header", 20_000);
      expect(await app.windowCount()).toBe(1);
      expect(await app.dialogs()).toEqual([]);
      const header = await app.find("overview.header");
      expect(typeof header["y"]).toBe("number");
      expect(Number(header["y"])).toBeGreaterThan(0);
      await app.screenshot("window-reopen");
    });
  });

  test("opens the review from the popover with the main window closed", async () => {
    await withApp(
      "popover-closed-window",
      {},
      async (app) => {
        await app.closeWindow();
        expect(await app.windowCount()).toBe(0);
        await app.openMenuBar();
        await app.find("menubar.quickClean", 20_000);
        await app.press("menubar.quickClean");
        await app.find("confirm.delete", 20_000);
        expect(await app.windowCount()).toBe(1);
        expect(await app.dialogs()).toEqual([]);
        await app.press("confirm.cancel");
        await app.waitGone("confirm.cancel");
      },
      seedCleanup,
    );
  });

  test("reopens the popover after routing to a module", async () => {
    await withApp("popover-reopen", {}, async (app) => {
      await app.openMenuBar();
      await app.press("menubar.module.storage");
      await app.find("storage.header");
      await app.openMenuBar();
      await app.find("menubar.open");
      await app.press("menubar.open");
      await app.find("storage.header");
      expect(await app.dialogs()).toEqual([]);
      await app.screenshot("popover-reopen");
    });
  });

  test("opens the main window from the File menu", async () => {
    await withApp("menu-open-window", {}, async (app) => {
      await app.closeWindow();
      await app.pressMenuItem("Open Dustless");
      await app.find("overview.header", 20_000);
      expect(await app.windowCount()).toBe(1);
      expect(await app.dialogs()).toEqual([]);
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
        await app.find("confirm.total");
        await app.press("confirm.cancel");
        await app.waitGone("confirm.cancel");
        expect(await exists(green)).toBe(true);
        expect(await exists(fail)).toBe(true);
        expect(await app.engineLog()).not.toContain("apply --json");

        await app.find("cleanup.review");
        await app.press("cleanup.review");
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

  test("captures the acceptance screens from the running app", async () => {
    const capture = async (app: UiApp, name: string) => {
      try {
        await app.screenshot(name);
      } catch (error) {
        console.log(`screenshot ${name} unavailable: ${String(error)}`);
      }
      await app.dump(name).catch(() => {});
    };
    await withApp("acceptance-en", {}, async (app) => {
      await app.find("overview.hero", 20_000);
      await Bun.sleep(400);
      await capture(app, "acceptance-overview");
      await app.openMenuBar();
      await app.find("menubar.open");
      await capture(app, "acceptance-popover");
      await app.press("menubar.quickClean");
      await app.find("confirm.delete");
      await capture(app, "acceptance-confirm");
      await app.press("confirm.cancel");
      await app.waitGone("confirm.cancel");
    }, seedCleanup);

    await withApp("acceptance-vi", { language: "vi" }, async (app) => {
      await app.find("overview.hero", 20_000);
      await Bun.sleep(400);
      await capture(app, "acceptance-overview-vi");
      await app.openMenuBar();
      await app.find("menubar.open");
      await capture(app, "acceptance-popover-vi");
    }, seedCleanup);
  });

  test("reaches the memory screen through the Go menu", async () => {
    await withApp("menu-navigation", {}, async (app) => {
      await app.pressMenuItem("Memory");
      await app.find("memory.header");
      await app.screenshot("menu-memory");
    });
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

  test("switches language live from settings", async () => {
    await withApp("language-live", { language: "en" }, async (app) => {
      await app.press("toolbar.settings");
      await app.find("settings.language");
      await app.press("settings.language");
      await app.pressLabel("Tiếng Việt");
      await Bun.sleep(500);
      expect(String((await app.find("overview.header")).value ?? "")).toBe("Tổng quan");
      await app.press("settings.language");
      await app.pressLabel("简体中文");
      await Bun.sleep(500);
      expect(String((await app.find("overview.header")).value ?? "")).toBe("概览");
      await app.screenshot("language-live");
    });
  });

  test("reads the selected language from the isolated preferences file", async () => {
    await withApp("language-vi", { language: "vi" }, async (app) => {
      const header = await app.find("overview.header");
      expect(String(header.value ?? "")).toBe("Tổng quan");
    });
  });

  test("filters cleanup findings and shows no matches", async () => {
    await withApp(
      "cleanup-filter",
      {},
      async (app) => {
        await app.pressMenuItem("Cleanup");
        await app.find("cleanup.title");
        await app.click("cleanup.tier.safe");
        await app.find("cleanup.search");
        await app.typeText("cleanup.search", "zzz-no-match");
        await app.find("cleanup.noMatches");
      },
      seedCleanup,
    );
  });

  test("cleans safely from the overview after a cancelled review", async () => {
    await withApp(
      "overview-quickclean",
      {},
      async (app) => {
        const green = join(app.home, ".dustless-e2e", "green");
        const fail = join(app.home, ".dustless-e2e", "fail");
        await app.find("overview.cleanSafely", 20_000);
        await app.press("overview.cleanSafely");
        await app.find("confirm.delete");
        await app.press("confirm.cancel");
        await app.waitGone("confirm.cancel");
        expect(await exists(green)).toBe(true);
        expect(await exists(fail)).toBe(true);
        expect(await app.engineLog()).not.toContain("apply --json");
        await Bun.sleep(500);
        await app.find("cleanup.review");
        await app.press("cleanup.review");
        await app.find("confirm.delete");
        await app.press("confirm.delete");
        await app.find("cleanup.result.counts", 30_000);
        const counts = await app.find("cleanup.result.counts");
        expect(String(counts.value ?? "")).toBe("2 deleted · 1 skipped · 0 failed");
        expect(await exists(green)).toBe(false);
        expect(await exists(fail)).toBe(false);
      },
      seedCleanup,
    );
  });

  test("cancels an advanced network operation without running it", async () => {
    await withApp("network-cancel", { intercepted: "both" }, async (app) => {
      await app.pressMenuItem("Network");
      await app.find("network.header");
      await app.press("network.advanced");
      await app.find("network.run.reset-dns");
      await app.press("network.run.reset-dns");
      await app.find("network.advanced.confirm");
      await app.press("network.advanced.cancel");
      await app.waitGone("network.advanced.cancel");
      expect(await app.engineLog()).not.toContain("net --reset-dns");
      expect(await app.exists("network.outcome.reset-dns")).toBe(false);
    });
  });

  test("runs network and AirDrop actions through the injected engine", async () => {
    await withApp("network", { intercepted: "both" }, async (app) => {
      await app.pressMenuItem("Network");
      await app.find("network.header");
      await app.press("network.advanced");
      await app.find("network.run.reset-dns");
      expect(await app.exists("network.remembered")).toBe(true);
      await app.waitForEngineLog((line) => line.includes("net --advanced"));
      await app.press("network.run.reset-dns");
      await app.find("network.advanced.confirm");
      await app.press("network.advanced.confirm");
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

  test("uninstalls the app bundle without touching related data when asked", async () => {
    await withApp(
      "applications-keep-data",
      {},
      async (app) => {
        const bundle = join(app.home, "Applications", "E2E Toy.app");
        const cache = join(app.home, "Library", "Caches", "dev.dustless.e2e.toy");
        await app.click("sidebar.module.applications");
        await app.find("applications.header");
        await app.find("applications.uninstall.dev.dustless.e2e.toy", 20_000);
        await app.press("applications.uninstall.dev.dustless.e2e.toy");
        await app.find("applications.confirm");
        await app.press("applications.confirm");
        await app.find("storage.result.close", 20_000);
        expect(await exists(bundle)).toBe(false);
        expect(await exists(cache)).toBe(true);
        await app.press("storage.result.close");
        await app.waitGone("storage.result.close");
        await app.waitGone("applications.app.dev.dustless.e2e.toy", 10_000);
      },
      async (app) => {
        await seedStorage(app);
      },
    );
  });

  test("reports a partial application uninstall without claiming success", async () => {
    if (process.getuid?.() === 0) return;
    await withApp(
      "applications-partial",
      {},
      async (app) => {
        const bundle = join(app.home, "Applications", "E2E Toy.app");
        const cache = join(app.home, "Library", "Caches", "dev.dustless.e2e.toy");
        const cachesParent = join(app.home, "Library", "Caches");
        await chmod(cachesParent, 0o500);
        try {
          await app.click("sidebar.module.applications");
          await app.find("applications.header");
          await app.find("applications.uninstall.dev.dustless.e2e.toy", 20_000);
          await app.press("applications.uninstall.dev.dustless.e2e.toy");
          await app.find("applications.confirm");
          await app.press("applications.includeRelated");
          await Bun.sleep(200);
          await app.press("applications.confirm");
          await app.find("storage.result.title", 20_000);
          const title = await app.find("storage.result.title");
          expect(String(title.value ?? "")).toBe("Partially removed");
          expect(await exists(bundle)).toBe(false);
          expect(await exists(cache)).toBe(true);
          await app.screenshot("applications-partial");
          await app.press("storage.result.close");
          await app.waitGone("storage.result.close");
        } finally {
          await chmod(cachesParent, 0o700);
        }
      },
      seedStorage,
    );
  });

  test("leaves a same-bundle-id copy at another path alone", async () => {
    const foreign: { value: Awaited<ReturnType<typeof startRunningAppFixture>> | null } = { value: null };
    try {
      await withApp(
        "applications-foreign-copy",
        {},
        async (app) => {
          await app.click("sidebar.module.applications");
          await app.find("applications.header");
          await app.find("applications.uninstall.dev.dustless.e2e.foreign", 20_000);
          await app.press("applications.uninstall.dev.dustless.e2e.foreign");
          await app.find("applications.confirm");
          await app.press("applications.confirm");
          await app.find("storage.result.title", 20_000);
          const target = join(app.home, "Applications", "Foreign Fixture.app");
          expect(await exists(target)).toBe(false);
          expect(processAlive(foreign.value!.pid)).toBe(true);
          await app.screenshot("applications-foreign-copy");
        },
        async (app) => {
          await seedStorage(app);
          foreign.value = await startRunningAppFixture(
            join(app.home, "Other", "Foreign Fixture.app"),
            "dev.dustless.e2e.foreign",
            "Foreign Fixture",
          );
          const target = join(app.home, "Applications", "Foreign Fixture.app");
          await mkdir(join(app.home, "Applications"), { recursive: true });
          const copied = Bun.spawnSync(["cp", "-R", foreign.value.appPath, target]);
          if (copied.exitCode !== 0) throw new Error("copy fixture failed");
        },
      );
    } finally {
      if (foreign.value) Bun.spawnSync(["pkill", "-f", foreign.value.appPath]);
      if (foreign.value) await rm(foreign.value.appPath, { recursive: true, force: true });
    }
  });

  test("uninstalls a running app only after it agrees to quit", async () => {
    await withApp(
      "applications-running",
      {},
      async (app) => {
        const fixture = await startRunningAppFixture(
          join(app.home, "Applications", "Running Fixture.app"),
          "dev.dustless.e2e.running",
          "Running Fixture",
        );
        try {
          await app.click("sidebar.module.applications");
          await app.find("applications.header");
          await app.find("applications.uninstall.dev.dustless.e2e.running", 20_000);
          await app.press("applications.uninstall.dev.dustless.e2e.running");
          await app.find("applications.confirm");
          await app.press("applications.confirm");
          await app.find("storage.result.title", 30_000);
          const deadline = Date.now() + 10_000;
          while (processAlive(fixture.pid) && Date.now() < deadline) await Bun.sleep(100);
          expect(processAlive(fixture.pid)).toBe(false);
          expect(await exists(fixture.appPath)).toBe(false);
          await app.screenshot("applications-running");
        } finally {
          Bun.spawnSync(["pkill", "-f", fixture.appPath]);
        }
      },
      seedStorage,
    );
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
        await app.click("sidebar.module.applications");
        await app.find("applications.header");
        await app.find("applications.uninstall.dev.dustless.e2e.toy", 20_000);
        await app.press("applications.uninstall.dev.dustless.e2e.toy");
        await app.find("applications.cancel");
        await app.press("applications.cancel");
        await app.waitGone("applications.cancel");
        expect(await exists(bundle)).toBe(true);
        expect(await exists(cache)).toBe(true);
        await app.press("applications.uninstall.dev.dustless.e2e.toy");
        await app.find("applications.confirm");
        await app.press("applications.includeRelated");
        await Bun.sleep(200);
        await app.press("applications.confirm");
        await app.find("storage.result.close", 20_000);
        await app.screenshot("applications-result");
        expect(await exists(bundle)).toBe(false);
        expect(await exists(cache)).toBe(false);
        await app.press("storage.result.close");
        await app.waitGone("storage.result.close");

        await app.pressMenuItem("Storage");
        await app.find("storage.header");
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
      async (app) => {
        await seedStorage(app);
        await seedLargeFile(app);
      },
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
        await app.pressMenuItem("Cleanup");
        await app.find("cleanup.title");
        await app.click("cleanup.tier.safe");
        await app.find("cleanup.selectAll");
        await app.press("cleanup.selectAll");
        const selected = await app.find("cleanup.selected");
        expect(String(selected.value ?? "")).toMatch(/^2 items selected\b/);
        await app.press("cleanup.review");
        await app.find("confirm.cancel");
        await app.screenshot("cleanup-confirm");
        await app.press("confirm.cancel");
        await app.waitGone("confirm.cancel");
        expect(await exists(green)).toBe(true);
        expect(await exists(fail)).toBe(true);
        await app.press("cleanup.selectNone");

        await app.click("cleanup.tier.locked");
        await app.find(`cleanup.locked.${blocked}`);
        const review = await app.find("cleanup.review");
        expect(review.enabled).toBe(false);

        await app.click("cleanup.tier.safe");
        await app.find("cleanup.selectAll");
        await app.press("cleanup.selectAll");
        const selectedAgain = await app.find("cleanup.selected");
        expect(String(selectedAgain.value ?? "")).toMatch(/^2 items selected\b/);
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

  test("quits a running app directly from its memory row", async () => {
    const fixture = await startQuitFixture();
    try {
      await withApp("memory-quit", {}, async (app) => {
        await app.pressMenuItem("Memory");
        await app.find("memory.header");
        await app.typeText("memory.search", "E2E Quit Fixture");
        await app.find(`memory.group.${fixture.bundlePath}`, 20_000);
        const quit = await app.find(`memory.quit.${fixture.bundlePath}`, 10_000);
        expect(quit.enabled).toBe(true);
        await app.press(`memory.quit.${fixture.bundlePath}`);
        const deadline = Date.now() + 10_000;
        while (processAlive(fixture.pid) && Date.now() < deadline) await Bun.sleep(100);
        expect(processAlive(fixture.pid)).toBe(false);
        await app.waitGone(`memory.group.${fixture.bundlePath}`, 10_000);
        await app.screenshot("memory-quit");
      });
    } finally {
      Bun.spawnSync(["pkill", "-f", fixture.root]);
      await rm(fixture.root, { recursive: true, force: true });
    }
  });

  test("stops only the sandboxed fixture process", async () => {
    const fixture = await startMemoryFixture();
    try {
      await withApp("memory", {}, async (app) => {
        expect(fixture.child.pid).toBeGreaterThan(0);
        expect(fixture.canary.pid).toBeGreaterThan(0);
        await app.pressMenuItem("Memory");
        await app.find("memory.header");
        await app.click("memory.filter.container");
        await app.find("memory.summary");
        await app.find(`memory.group.${fixture.binary}`, 20_000);
        if (!(await app.exists(`memory.stop.${fixture.child.pid}`))) {
          await app.press(`memory.expand.${fixture.binary}`);
        }
        await app.find(`memory.stop.${fixture.child.pid}`, 20_000);
        await app.press(`memory.stop.${fixture.child.pid}`);
        await app.find("memory.stop.cancel");
        await app.press("memory.stop.cancel");
        await app.waitGone("memory.stop.cancel");
        expect(processAlive(fixture.child.pid!)).toBe(true);
        await app.press(`memory.stop.${fixture.child.pid}`);
        await app.find("memory.stop.confirm");
        await app.press("memory.stop.confirm");
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
