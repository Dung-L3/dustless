import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, stat, readdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { listApps, uninstall } from "../src/core/apps/index.ts";
import { assertTempRoot } from "./e2e/harness.ts";

const TMP = tmpdir();
let home: string;
let appsDir: string;
let libraryDir: string;
let trashDir: string;

beforeAll(async () => {
  home = assertTempRoot(await mkdtemp(join(TMP, "dustless-apps-")));
  appsDir = join(home, "Applications");
  libraryDir = join(home, "Library");
  trashDir = join(home, ".Trash");
  await mkdir(appsDir, { recursive: true });
  await mkdir(libraryDir, { recursive: true });
  await mkdir(trashDir, { recursive: true });

  const appBundle = join(appsDir, "MyApp.app");
  await mkdir(join(appBundle, "Contents", "MacOS"), { recursive: true });
  await mkdir(join(appBundle, "Contents", "Resources"), { recursive: true });
  await writeFile(
    join(appBundle, "Contents", "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.example.myapp</string>
  <key>CFBundleName</key>
  <string>MyApp</string>
  <key>CFBundleDisplayName</key>
  <string>MyApp Display</string>
  <key>CFBundleVersion</key>
  <string>1.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
</dict>
</plist>`,
  );
  await writeFile(join(appBundle, "Contents", "MacOS", "MyApp"), "#!/bin/sh\necho hello\n");
  await writeFile(join(appBundle, "Contents", "Resources", "data.bin"), Buffer.alloc(1024 * 100, 0x42));

  const leftovers = [
    "Application Support/com.example.myapp",
    "Caches/com.example.myapp",
    "Preferences/com.example.myapp.plist",
    "Logs/com.example.myapp",
    "Saved Application State/com.example.myapp.savedState",
    "Containers/com.example.myapp",
    "Group Containers/com.example.myapp",
    "WebKit/com.example.myapp",
    "HTTPStorages/com.example.myapp",
    "Application Scripts/com.example.myapp",
    "LaunchAgents/com.example.myapp.plist",
    "Cookies/com.example.myapp.binarycookies",
  ];

  for (const rel of leftovers) {
    const full = join(libraryDir, rel);
    await mkdir(dirname(full), { recursive: true });
    if (full.endsWith(".plist") || full.endsWith(".binarycookies")) {
      await writeFile(full, "leftover data");
    } else {
      await mkdir(full, { recursive: true });
      await writeFile(join(full, "cache.bin"), Buffer.alloc(512, 0x55));
    }
  }

  const otherApp = join(appsDir, "OtherApp.app");
  await mkdir(join(otherApp, "Contents", "MacOS"), { recursive: true });
  await writeFile(
    join(otherApp, "Contents", "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.example.other</string>
  <key>CFBundleName</key>
  <string>OtherApp</string>
</dict>
</plist>`,
  );
});

afterAll(async () => {
  await rm(home, { recursive: true, force: true });
});

function dirname(path: string): string {
  return path.split(/[/\\]/).slice(0, -1).join("/");
}

async function createTestApp(bundleId: string, name: string, appDir: string): Promise<string> {
  const appPath = join(appDir, `${name}.app`);
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

async function createLeftover(home: string, bundleId: string, relPath: string): Promise<void> {
  const full = join(home, "Library", relPath.replace("{id}", bundleId));
  await mkdir(dirname(full), { recursive: true });
  if (full.endsWith(".plist") || full.endsWith(".binarycookies")) {
    await writeFile(full, "leftover data");
  } else {
    await mkdir(full, { recursive: true });
    await writeFile(join(full, "cache.bin"), Buffer.alloc(512, 0x55));
  }
}

describe("listApps", () => {
  test("finds .app bundles and reads bundle id and name", async () => {
    const apps = await listApps({ home, appDirs: [appsDir] });
    expect(apps.length).toBe(2);
    const myApp = apps.find((a) => a.bundleId === "com.example.myapp");
    expect(myApp).toBeDefined();
    if (!myApp) return;
    expect(myApp.name).toBe("MyApp Display");
    expect(myApp.path).toBe(join(appsDir, "MyApp.app"));
    expect(myApp.bytes).toBeGreaterThan(0);
  });

  test("lists only existing related paths derived from bundle id", async () => {
    const apps = await listApps({ home, appDirs: [appsDir] });
    const myApp = apps.find((a) => a.bundleId === "com.example.myapp");
    expect(myApp).toBeDefined();
    if (!myApp) return;
    expect(myApp.relatedPaths.length).toBe(12);
    for (const p of myApp.relatedPaths) {
      expect(p).toContain("com.example.myapp");
    }
  });

  test("excludes non-existing related paths for apps without leftovers", async () => {
    const apps = await listApps({ home, appDirs: [appsDir] });
    const otherApp = apps.find((a) => a.bundleId === "com.example.other");
    expect(otherApp).toBeDefined();
    if (!otherApp) return;
    expect(otherApp.relatedPaths.length).toBe(0);
  });
});

describe("uninstall", () => {
  test("refuses without confirm", async () => {
    const apps = await listApps({ home, appDirs: [appsDir] });
    const target = apps.find((a) => a.bundleId === "com.example.myapp")!;
    const report = await uninstall({
      home,
      appPath: target.path,
      relatedPaths: target.relatedPaths,
      confirm: false,
    });
    expect(report.summary.failed).toBe(1 + target.relatedPaths.length);
    expect(report.outcomes[0]!.detail?.code).toBe("confirm_required");
  });

  test("refuses path outside sandbox home", async () => {
    const outside = assertTempRoot(await mkdtemp(join(TMP, "dustless-outside-")));
    const apps = await listApps({ home, appDirs: [appsDir] });
    const target = apps.find((a) => a.bundleId === "com.example.myapp");
    expect(target).toBeDefined();
    const report = await uninstall({
      home,
      appPath: join(outside, "MyApp.app"),
      relatedPaths: [],
      confirm: true,
    });
    expect(report.summary.failed).toBe(1);
    expect(report.outcomes[0]!.detail?.code).toBe("not_allowed_dir");
    await rm(outside, { recursive: true, force: true });
  });

  test("refuses deny-listed paths (HOME, Library, etc.)", async () => {
    const apps = await listApps({ home, appDirs: [appsDir] });
    const target = apps.find((a) => a.bundleId === "com.example.myapp");
    expect(target).toBeDefined();

    const report = await uninstall({
      home,
      appPath: home,
      relatedPaths: [],
      confirm: true,
    });
    expect(report.summary.failed).toBe(1);
    expect(report.outcomes[0]!.detail?.code).toBe("not_an_app");
  });

  test.skipIf(process.platform === "win32")("refuses system app path", async () => {
    const apps = await listApps({ home, appDirs: [appsDir] });
    const target = apps.find((a) => a.bundleId === "com.example.myapp");
    expect(target).toBeDefined();
    const report = await uninstall({
      home,
      appPath: "/System/Applications/Fake.app",
      relatedPaths: [],
      confirm: true,
    });
    expect(report.summary.failed).toBe(1);
    expect(report.outcomes[0]!.detail?.code).toBe("system_app");
  });

  test("moves app and related paths to trash on confirm", async () => {
    const apps = await listApps({ home, appDirs: [appsDir] });
    const target = apps.find((a) => a.bundleId === "com.example.myapp")!;

    const report = await uninstall({
      home,
      appPath: target.path,
      relatedPaths: target.relatedPaths,
      confirm: true,
    });

    expect(report.summary.trashed).toBe(1 + target.relatedPaths.length);
    expect(report.summary.failed).toBe(0);
    expect(report.summary.skipped).toBe(0);

    expect(await stat(target.path).then(() => false, () => true)).toBe(true);
    for (const p of target.relatedPaths) {
      expect(await stat(p).then(() => false, () => true)).toBe(true);
    }

    const trashContents = await readdir(trashDir, { withFileTypes: true });
    expect(trashContents.length).toBeGreaterThanOrEqual(1 + target.relatedPaths.length);

    const otherApp = apps.find((a) => a.bundleId === "com.example.other")!;
    expect(await stat(otherApp.path).then(() => true, () => false)).toBe(true);
  });

  test("purge permanently deletes instead of trashing", async () => {
    const appBundle = join(appsDir, "PurgeApp.app");
    await mkdir(join(appBundle, "Contents", "MacOS"), { recursive: true });
    await writeFile(
      join(appBundle, "Contents", "Info.plist"),
      `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.example.purge</string>
  <key>CFBundleName</key>
  <string>PurgeApp</string>
</dict>
</plist>`,
    );
    await writeFile(join(appBundle, "Contents", "MacOS", "PurgeApp"), "#!/bin/sh\n");

    const leftoverDir = join(libraryDir, "Application Support", "com.example.purge");
    await mkdir(leftoverDir, { recursive: true });
    await writeFile(join(leftoverDir, "data.bin"), Buffer.alloc(256, 0x66));

    const apps = await listApps({ home, appDirs: [appsDir] });
    const target = apps.find((a) => a.bundleId === "com.example.purge")!;

    const report = await uninstall({
      home,
      appPath: target.path,
      relatedPaths: target.relatedPaths,
      confirm: true,
      purge: true,
    });

    expect(report.summary.purged).toBe(1 + target.relatedPaths.length);
    expect(report.summary.trashed).toBe(0);

    expect(await stat(target.path).then(() => false, () => true)).toBe(true);
    for (const p of target.relatedPaths) {
      expect(await stat(p).then(() => false, () => true)).toBe(true);
    }
  });

  test("skips non-existing related paths", async () => {
    await createTestApp("com.example.myapp", "MyApp", appsDir);
    await createLeftover(home, "com.example.myapp", "Application Support/{id}");
    await createLeftover(home, "com.example.myapp", "Caches/{id}");

    const apps = await listApps({ home, appDirs: [appsDir] });
    const target = apps.find((a) => a.bundleId === "com.example.myapp")!;

    const nonExistingValid = join(home, "Library", "Logs", "com.example.myapp");
    const withExtra = [...target.relatedPaths, nonExistingValid];

    const report = await uninstall({
      home,
      appPath: target.path,
      relatedPaths: withExtra,
      confirm: true,
    });

    const skipped = report.outcomes.filter((o) => o.status === "skipped");
    expect(skipped.length).toBe(1);
    expect(skipped[0]!.detail?.code).toBe("not_found");
  });

  test("refuses unrelated paths not in relatedPaths list", async () => {
    await createTestApp("com.example.myapp", "MyApp", appsDir);
    await createTestApp("com.example.other", "OtherApp", appsDir);
    await createLeftover(home, "com.example.myapp", "Application Support/{id}");

    const apps = await listApps({ home, appDirs: [appsDir] });
    const target = apps.find((a) => a.bundleId === "com.example.myapp")!;
    const otherApp = apps.find((a) => a.bundleId === "com.example.other")!;

    const report = await uninstall({
      home,
      appPath: target.path,
      relatedPaths: [...target.relatedPaths, otherApp.path],
      confirm: true,
    });

    const failed = report.outcomes.find((o) => o.path === otherApp.path);
    expect(failed?.status).toBe("failed");
    expect(failed?.detail?.code).toBe("not_a_leftover");
  });
});

describe("a crafted CFBundleIdentifier cannot aim the uninstall outside HOME", () => {
  const TRAVERSAL = "../../../victim";
  let root: string;
  let box: { home: string; victim: string; appPath: string };
  const survives = async (): Promise<boolean> => await stat(join(box.victim, "precious.txt")).then(() => true, () => false);

  beforeAll(async () => {
    root = assertTempRoot(await mkdtemp(join(TMP, "dustless-apps-traversal-")));
    const home = join(root, "home");
    const victim = join(root, "victim");
    await mkdir(victim, { recursive: true });
    await writeFile(join(victim, "precious.txt"), "not yours to delete");
    await mkdir(join(home, "Library", "Caches"), { recursive: true });
    await writeFile(join(home, "Library", "Caches", "precious.txt"), "cache contents");
    const appPath = await createTestApp(TRAVERSAL, "Evil", join(home, "Applications"));
    box = { home, victim, appPath };
  });

  afterAll(async () => {
    await rm(root, { recursive: true, force: true });
  });

  test("no leftover path is derived from an id that contains a traversal", async () => {
    expect(join(box.home, "Library", "Caches", TRAVERSAL)).toBe(box.victim);
    expect(box.victim.startsWith(box.home + "/")).toBe(false);

    const apps = await listApps({ home: box.home, appDirs: [join(box.home, "Applications")] });
    const evil = apps.find((a) => a.bundleId === TRAVERSAL);
    expect(evil).toBeDefined();
    expect(evil!.relatedPaths).toEqual([]);
  });

  test("--purge refuses the whole uninstall and the victim survives", async () => {
    const report = await uninstall({
      home: box.home,
      appPath: box.appPath,
      relatedPaths: [box.victim, join(box.home, "Library", "Caches", TRAVERSAL)],
      confirm: true,
      purge: true,
    });
    expect(report.summary.purged).toBe(0);
    expect(report.summary.trashed).toBe(0);
    expect(report.summary.failed).toBe(1);
    expect(report.outcomes[0]!.detail?.code).toBe("bad_bundle_id");
    expect(await survives()).toBe(true);
    expect(await stat(box.appPath).then(() => true, () => false)).toBe(true);
  });

  test("a traversal id is refused when trashing too, and nothing is moved", async () => {
    const report = await uninstall({ home: box.home, appPath: box.appPath, relatedPaths: [], confirm: true });
    expect(report.summary.trashed).toBe(0);
    expect(report.summary.purged).toBe(0);
    expect(await survives()).toBe(true);
  });

  test("a bundle id with a path separator or a traversal token is refused", async () => {
    for (const id of ["com/example", "com\\example", "..", "a/../../b"]) {
      const appPath = await createTestApp(id, "Slashy", join(box.home, "Applications"));
      const report = await uninstall({ home: box.home, appPath, relatedPaths: [], confirm: true, purge: true });
      expect({ id, purged: report.summary.purged, trashed: report.summary.trashed }).toEqual({ id, purged: 0, trashed: 0 });
      expect(await stat(appPath).then(() => true, () => false)).toBe(true);
    }
    expect(await survives()).toBe(true);
  });

  test("a '.' or control-character bundle id cannot collapse leftovers onto Library directories", async () => {
    const caches = join(box.home, "Library", "Caches");
    for (const [id, name] of [[".", "Dot"], ["com.example\u0000evil", "Nul"]] as const) {
      const appPath = await createTestApp(id, name, join(box.home, "Applications"));
      const report = await uninstall({ home: box.home, appPath, relatedPaths: [caches], confirm: true, purge: true });
      expect({ id, purged: report.summary.purged, trashed: report.summary.trashed }).toEqual({ id, purged: 0, trashed: 0 });
    expect(report.outcomes[0]!.detail?.code).toBe("bad_bundle_id");
      expect(await stat(join(caches, "precious.txt")).then(() => true, () => false)).toBe(true);
      expect(await stat(appPath).then(() => true, () => false)).toBe(true);
      await rm(appPath, { recursive: true, force: true });
    }
    expect(await survives()).toBe(true);
  });

  test("a leftover that resolves outside HOME is refused on its own", async () => {
    const good = await createTestApp("com.example.good", "Good", join(box.home, "Applications"));
    const report = await uninstall({ home: box.home, appPath: good, relatedPaths: [box.victim], confirm: true });
    expect(report.summary.trashed).toBe(0);
    expect(report.summary.failed).toBe(1);
    expect(report.outcomes[0]!.detail?.code).toBe("leftover_escapes_home");
    expect(await survives()).toBe(true);
    expect(await stat(good).then(() => true, () => false)).toBe(true);
  });
});