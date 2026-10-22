import { chmod, copyFile, mkdir, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { spawn } from "node:child_process";
import { join } from "node:path";
import { APP_SRC, DIST, ROOT, fail, readVersion, run, runInherit } from "./lib.ts";
import { architectures, inspectSignature, resolveSigning, sha256, signApplication } from "./mac-signing.ts";
import { readImageFacts } from "./mac-image.ts";

const APP = process.env["DUSTLESS_BUNDLE_OUT"] ?? join(DIST, "Dustless.app");
const ENGINE = process.env["DUSTLESS_ENGINE"] ?? join(DIST, "dustless");
const ICON = existsSync(join(DIST, "icons", "dustless.icns"))
  ? join(DIST, "icons", "dustless.icns")
  : join(ROOT, "brand", "generated", "dustless.icns");
const MENUBAR_ICON = join(APP_SRC, "Assets", "MenuBarIcon.png");
const RECORD = join(DIST, "macos-release.json");
const BUNDLE_ID = "dev.dustless.mac";
const ARCH = "arm64";
const SWIFT_FLAGS = process.env["DUSTLESS_UI_TESTING"] === "1"
  ? ["-Xswiftc", "-DDUSTLESS_UI_TESTING"]
  : [];

function infoPlist(version: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Dustless</string>
  <key>CFBundleDisplayName</key><string>Dustless</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>Dustless</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>CFBundleIconFile</key><string>Dustless.icns</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
`;
}

function runEngine(engine: string, args: string[], timeoutMs: number): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(engine, args, { stdio: ["ignore", "pipe", "pipe"] });
    } catch (error) {
      resolve({ code: -1, stdout: "", stderr: error instanceof Error ? error.message : String(error) });
      return;
    }
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("error", (error) => {
      clearTimeout(timer);
      resolve({ code: -1, stdout, stderr: error.message });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code: code ?? -1, stdout, stderr });
    });
  });
}

const version = await readVersion();

if (!existsSync(ENGINE)) fail(`missing ${ENGINE} — run \`bun run build\` first`);
if (!existsSync(ICON)) fail(`missing ${ICON} — regenerate icons first`);
if (!existsSync(MENUBAR_ICON)) fail(`missing ${MENUBAR_ICON} — the menu bar template image is committed under apps/dustless-mac/Assets`);

const started = Date.now();

const built = await runInherit("swift", ["build", "--package-path", APP_SRC, "-c", "release", ...SWIFT_FLAGS]);
if (built !== 0) fail("swift build -c release failed");

const binDir = (
  await run("swift", ["build", "--package-path", APP_SRC, "-c", "release", ...SWIFT_FLAGS, "--show-bin-path"])
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
await chmod(ENGINE, 0o755);

const engineSourceHash = await sha256(ENGINE);
const engineBundleHash = await sha256(join(APP, "Contents", "Resources", "dustless"));
if (engineSourceHash !== engineBundleHash) {
  fail(`the bundle holds a different engine than ${ENGINE} — the copy is stale`);
}

const engineArch = await architectures(join(APP, "Contents", "Resources", "dustless"));
if (engineArch !== ARCH) fail(`the bundled engine is ${engineArch}, the macOS app must ship ${ARCH}`);
const appArch = await architectures(join(APP, "Contents", "MacOS", "Dustless"));
if (appArch !== ARCH) fail(`the app executable is ${appArch}, the macOS app must ship ${ARCH}`);

const sourceVersion = await runEngine(ENGINE, ["version"], 20_000);
if (sourceVersion.code !== 0) {
  fail(`the engine at ${ENGINE} did not answer \`version\`: ${sourceVersion.stderr.trim() || sourceVersion.stdout.trim()}`);
}
if (sourceVersion.stdout.trim() !== version) {
  fail(`the engine at ${ENGINE} reports ${sourceVersion.stdout.trim()} but the app is ${version}`);
}

const icon = await readImageFacts(join(APP, "Contents", "Resources", "MenuBarIcon.png"));
if (!icon.hasAlpha) fail("the menu bar image has no alpha channel, it cannot be a template image");
if (icon.distinct < 2) fail("the menu bar image is one solid colour, it would paint a square in the menu bar");
if (icon.transparent === 0) fail("the menu bar image is fully opaque, it would paint a square in the menu bar");
if (!icon.grayscale) fail("the menu bar image is not greyscale, it cannot be a template image");
if (icon.width < 16 || icon.height < 16) fail(`the menu bar image is ${icon.width}x${icon.height}, too small to read`);

await writeFile(join(APP, "Contents", "Info.plist"), infoPlist(version));

const lint = await run("plutil", ["-lint", join(APP, "Contents", "Info.plist")]);
if (lint.code !== 0) fail(`Info.plist failed plutil -lint: ${lint.stderr}`);

const plist = await run("plutil", ["-p", join(APP, "Contents", "Info.plist")]);
if (plist.code !== 0) fail(`Info.plist could not be read back: ${plist.stderr.trim()}`);
const plistText = plist.stdout;
if (!plistText.includes(`"${BUNDLE_ID}"`)) fail(`Info.plist does not carry the bundle identifier ${BUNDLE_ID}`);
if (!plistText.includes(`"${version}"`)) fail(`Info.plist does not carry the version ${version}`);
if (/LSUIElement/.test(plistText)) fail("Info.plist carries LSUIElement, the app must stay a normal application");

const plan = await resolveSigning();
await signApplication(APP, plan);
const signature = await inspectSignature(APP);
if (plan.kind === "developer-id" && signature.kind !== "developer-id") {
  fail(`the bundle was supposed to carry a Developer ID signature but carries ${signature.kind}`);
}
if (plan.kind === "adhoc" && signature.kind !== "adhoc") {
  fail(`the bundle was supposed to be ad-hoc signed but carries ${signature.kind}`);
}

const bundledEngine = join(APP, "Contents", "Resources", "dustless");
const probe = await runEngine(bundledEngine, ["version"], 20_000);
if (probe.code !== 0) {
  fail(`the bundled engine did not answer \`version\`: ${probe.stderr.trim() || probe.stdout.trim() || `exit ${probe.code}`}`);
}
const reported = probe.stdout.trim();
if (!reported) fail("the bundled engine printed no version");
if (reported !== version) {
  fail(`the bundled engine reports ${reported} but the app is ${version} — rebuild it with \`bun run build\``);
}

const record = {
  version,
  bundleIdentifier: BUNDLE_ID,
  mode: signature.kind,
  identity: signature.authority,
  teamIdentifier: signature.team,
  notarized: false,
  submissionId: null,
  engineSha256: engineBundleHash,
  app: APP,
  icon: { width: icon.width, height: icon.height, distinctColours: icon.distinct, transparentPixels: icon.transparent },
};
await writeFile(RECORD, `${JSON.stringify(record, null, 2)}\n`);

const how = signature.kind === "developer-id"
  ? `signed with ${signature.authority ?? "a Developer ID"}`
  : "ad-hoc signed (no Developer ID, so Gatekeeper will block it)";
console.log(`done ${APP} in ${((Date.now() - started) / 1000).toFixed(1)}s (version ${version}, ${how})`);
console.log(`engine ${reported}, ${ARCH}, sha256 ${engineBundleHash}`);
console.log(`menu bar image ${icon.width}x${icon.height}, ${icon.distinct} colours, ${icon.transparent} transparent pixels`);
console.log(`record written to ${RECORD}`);
