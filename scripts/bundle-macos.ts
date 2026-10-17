import { chmod, copyFile, mkdir, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { APP_SRC, DIST, fail, readVersion, run, runInherit } from "./lib.ts";

const APP = join(DIST, "Dustless.app");
const ENGINE = join(DIST, "dustless");
const ICON = join(DIST, "icons", "dustless.icns");
const MENUBAR_ICON = join(APP_SRC, "Assets", "MenuBarIcon.png");

function infoPlist(version: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Dustless</string>
  <key>CFBundleDisplayName</key><string>Dustless</string>
  <key>CFBundleIdentifier</key><string>dev.dustless.mac</string>
  <key>CFBundleExecutable</key><string>Dustless</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>CFBundleIconFile</key><string>Dustless.icns</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
`;
}

const version = await readVersion();

if (!existsSync(ENGINE)) fail(`missing ${ENGINE} — run \`bun run build\` first`);
if (!existsSync(ICON)) fail(`missing ${ICON} — regenerate icons first`);
if (!existsSync(MENUBAR_ICON)) fail(`missing ${MENUBAR_ICON} — the menu bar template image is committed under apps/dustless-mac/Assets`);

const started = Date.now();

const built = await runInherit("swift", ["build", "--package-path", APP_SRC, "-c", "release"]);
if (built !== 0) fail("swift build -c release failed");

const binDir = (
  await run("swift", ["build", "--package-path", APP_SRC, "-c", "release", "--show-bin-path"])
).stdout.trim();
const swiftBin = join(binDir, "DustlessApp");

await rm(APP, { recursive: true, force: true });
await mkdir(join(APP, "Contents", "MacOS"), { recursive: true });
await mkdir(join(APP, "Contents", "Resources"), { recursive: true });

await copyFile(swiftBin, join(APP, "Contents", "MacOS", "Dustless"));
await copyFile(ENGINE, join(APP, "Contents", "Resources", "dustless"));
await copyFile(ICON, join(APP, "Contents", "Resources", "Dustless.icns"));
await copyFile(MENUBAR_ICON, join(APP, "Contents", "Resources", "MenuBarIcon.png"));

await chmod(join(APP, "Contents", "MacOS", "Dustless"), 0o755);
await chmod(join(APP, "Contents", "Resources", "dustless"), 0o755);

await writeFile(join(APP, "Contents", "Info.plist"), infoPlist(version));

const lint = await run("plutil", ["-lint", join(APP, "Contents", "Info.plist")]);
if (lint.code !== 0) fail(`Info.plist failed plutil -lint: ${lint.stderr}`);

const signed = await run("codesign", ["--force", "--deep", "--sign", "-", APP]);
if (signed.code !== 0) fail(`codesign failed: ${signed.stderr.trim()}`);

const verified = await run("codesign", ["--verify", "--deep", APP]);
if (verified.code !== 0) fail(`codesign --verify failed: ${verified.stderr.trim()}`);

console.log(`done ${APP} in ${((Date.now() - started) / 1000).toFixed(1)}s (version ${version}, ad-hoc signed)`);
