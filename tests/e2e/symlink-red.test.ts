import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdir, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import {
  applyJson,
  cleanupAll,
  digest,
  sandbox,
  treeBytes,
  type Sandbox,
  type ApplyReport,
} from "./harness.ts";

const exists = async (path: string): Promise<boolean> => await stat(path).then(() => true, () => false);

afterAll(cleanupAll);

describe("symlink-red: real escape test - red directory protected through symlinks", () => {
  let box: Sandbox;
  const canaryContent = "CANARY-UNIQUE-CONTENT-SYMLINK-RED-TEST-" + Date.now();
  let redDir: string;
  let canaryFile: string;
  let cacheDir: string;
  let symlinkToRed: string;
  let symlinkToRedTrailingTarget: string;

  beforeAll(async () => {
    box = await sandbox("symlink-red");
    redDir = join(box.home, "Documents");
    canaryFile = join(redDir, "canary.txt");
    cacheDir = join(box.home, "Library", "Caches", "testcache");
    symlinkToRed = join(cacheDir, "link-to-documents");
    symlinkToRedTrailingTarget = join(cacheDir, "link-to-documents-trailing");

    await mkdir(redDir, { recursive: true });
    await writeFile(canaryFile, canaryContent);
    await mkdir(cacheDir, { recursive: true });
    await symlink(redDir, symlinkToRed);
    await symlink(redDir + "/", symlinkToRedTrailingTarget);
  });

  afterAll(async () => {
    await box.dispose();
  });

  test("canary exists in red directory before any deletion attempt", async () => {
    expect(await exists(canaryFile)).toBe(true);
    const content = await readFile(canaryFile, "utf8");
    expect(content).toBe(canaryContent);
    expect(await treeBytes(redDir)).toBeGreaterThan(0);
  });

  test("apply --yes with symlink path refuses deletion and preserves canary", async () => {
    const beforeDigest = await digest(redDir);
    const run = await box.run(["apply", "--yes", "--json"], { cwd: "/" });
    expect(run.code).toBe(0);
    const report = applyJson(run.stdout);
    const symlinkOutcome = report.outcomes.find(o => o.path === symlinkToRed || o.path === symlinkToRedTrailingTarget);
    if (symlinkOutcome) {
      expect(symlinkOutcome.status).toBe("failed");
      expect(symlinkOutcome.detail).toContain("từ chối: nằm trong danh sách đỏ");
    }
    expect(await exists(canaryFile)).toBe(true);
    const content = await readFile(canaryFile, "utf8");
    expect(content).toBe(canaryContent);
    expect(await digest(redDir)).toBe(beforeDigest);
    expect(await treeBytes(redDir)).toBeGreaterThan(0);
  });

  test("apply --only-file with symlink path refuses deletion and preserves canary", async () => {
    const tempFile = join(box.home, "selection.json");
    await writeFile(tempFile, JSON.stringify([symlinkToRed]));
    const beforeDigest = await digest(redDir);
    const run = await box.run(["apply", "--only-file", tempFile, "--json"]);
    expect(run.code).toBe(0);
    const report = applyJson(run.stdout);
    const symlinkOutcome = report.outcomes.find(o => o.path === symlinkToRed);
    if (symlinkOutcome) {
      expect(symlinkOutcome.status).toBe("failed");
      expect(symlinkOutcome.detail).toContain("từ chối: nằm trong danh sách đỏ");
    }
    expect(await exists(canaryFile)).toBe(true);
    const content = await readFile(canaryFile, "utf8");
    expect(content).toBe(canaryContent);
    expect(await digest(redDir)).toBe(beforeDigest);
    await rm(tempFile).catch(() => undefined);
  });

  test("largefiles --delete with symlink path refuses deletion and preserves canary", async () => {
    const beforeDigest = await digest(redDir);
    const run = await box.run(["largefiles", "--delete", symlinkToRed, "--confirm", "--json"]);
    expect(run.code).toBe(1);
    const report = JSON.parse(run.stdout) as ApplyReport;
    const outcome = report.outcomes.find(o => o.path === symlinkToRed);
    expect(outcome).toBeDefined();
    expect(outcome?.status).toBe("failed");
    expect(outcome?.detail).toContain("red list");
    expect(await exists(canaryFile)).toBe(true);
    const content = await readFile(canaryFile, "utf8");
    expect(content).toBe(canaryContent);
    expect(await digest(redDir)).toBe(beforeDigest);
    expect(await treeBytes(redDir)).toBeGreaterThan(0);
  });

  test("largefiles --delete with symlink-to-trailing-target path refuses deletion and preserves canary", async () => {
    const beforeDigest = await digest(redDir);
    const run = await box.run(["largefiles", "--delete", symlinkToRedTrailingTarget, "--confirm", "--json"]);
    expect(run.code).toBe(1);
    const report = JSON.parse(run.stdout) as ApplyReport;
    const outcome = report.outcomes.find(o => o.path === symlinkToRedTrailingTarget);
    expect(outcome).toBeDefined();
    expect(outcome?.status).toBe("failed");
    expect(outcome?.detail).toContain("red list");
    expect(await exists(canaryFile)).toBe(true);
    const content = await readFile(canaryFile, "utf8");
    expect(content).toBe(canaryContent);
    expect(await digest(redDir)).toBe(beforeDigest);
    expect(await treeBytes(redDir)).toBeGreaterThan(0);
  });

  test("apps --uninstall with bundle planted at symlink path: scan does not follow symlinks, so bundle not in inventory; this is a known limitation", async () => {
    const bundlePath = join(symlinkToRed, "TestApp.app");
    await mkdir(join(bundlePath, "Contents", "MacOS"), { recursive: true });
    await writeFile(join(bundlePath, "Contents", "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
<key>CFBundleIdentifier</key><string>com.test.symlinkred</string>
<key>CFBundleName</key><string>TestApp</string>
<key>CFBundleExecutable</key><string>TestApp</string>
<key>CFBundleVersion</key><string>1.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>`);
    await writeFile(join(bundlePath, "Contents", "MacOS", "TestApp"), "#!/bin/sh\necho test\n");
    await Bun.$`chmod +x ${join(bundlePath, "Contents", "MacOS", "TestApp")}`.quiet();

    const beforeDigest = await digest(redDir);
    const run = await box.run(["apps", "--uninstall", bundlePath, "--confirm", "--json"]);
    expect(run.code).toBe(1);
    const report = JSON.parse(run.stdout) as { error: string; path: string };
    expect(report.error).toBe("app not found in inventory");
    expect(report.path).toBe(bundlePath);
    expect(await exists(canaryFile)).toBe(true);
    const content = await readFile(canaryFile, "utf8");
    expect(content).toBe(canaryContent);
    expect(await digest(redDir)).toBe(beforeDigest);
    expect(await treeBytes(redDir)).toBeGreaterThan(0);
  });

  test("symlink target directory itself is not emptied after all attempts", async () => {
    expect(await exists(redDir)).toBe(true);
    expect(await treeBytes(redDir)).toBeGreaterThan(0);
    expect(await exists(canaryFile)).toBe(true);
    const content = await readFile(canaryFile, "utf8");
    expect(content).toBe(canaryContent);
  });
});