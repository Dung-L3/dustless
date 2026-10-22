import { lstat, mkdtemp, readdir, readlink, rm, stat, symlink } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { DIST, fail, readVersion, run } from "./lib.ts";
import { sha256 } from "./mac-signing.ts";

const APP = join(DIST, "Dustless.app");
const version = await readVersion();
const DMG = join(DIST, `Dustless-${version}.dmg`);
const VOLUME = "Dustless";

if (!existsSync(join(APP, "Contents", "MacOS", "Dustless"))) {
  fail(`${APP} missing — run \`bun run bundle:mac\` first`);
}

async function treeBytes(path: string): Promise<number> {
  const info = await lstat(path);
  if (info.isSymbolicLink()) return (await readlink(path)).length;
  if (!info.isDirectory()) return info.size;
  const entries = await readdir(path);
  let total = 0;
  for (const entry of entries) total += await treeBytes(join(path, entry));
  return total;
}

function parseAttach(stdout: string): { device: string | null; mountPoint: string | null } {
  const lines = stdout.split("\n").map((line) => line.trim()).filter(Boolean);
  const last = lines[lines.length - 1] ?? "";
  const fields = last.split(/\s+/);
  return {
    device: fields[0]?.startsWith("/dev/") ? fields[0] : null,
    mountPoint: fields.find((field) => field.startsWith("/Volumes/")) ?? null,
  };
}

const started = Date.now();
const stage = await mkdtemp(join(tmpdir(), "dustless-dmg-stage-"));

try {
  const copied = await run("ditto", [APP, join(stage, "Dustless.app")]);
  if (copied.code !== 0) fail(`ditto failed: ${copied.stderr.trim()}`);
  await symlink("/Applications", join(stage, "Applications"));

  const stagedSignature = await run("codesign", ["--verify", "--deep", join(stage, "Dustless.app")]);
  if (stagedSignature.code !== 0) {
    fail(`ditto did not carry the signature into the image: ${stagedSignature.stderr.trim()}`);
  }
  const stagedEngine = join(stage, "Dustless.app", "Contents", "Resources", "dustless");
  const stagedHash = await sha256(stagedEngine);
  const sourceHash = await sha256(join(APP, "Contents", "Resources", "dustless"));
  if (stagedHash !== sourceHash) fail("the staged engine is not the engine that was bundled");

  const stagedBytes = await treeBytes(stage);
  if (stagedBytes <= 0) fail("the staging folder is empty");

  let created: Awaited<ReturnType<typeof run>> | null = null;
  const createSpec = ["create", "-volname", VOLUME, "-srcfolder", stage, "-ov", "-format", "UDZO", DMG] as const;
  for (let attempt = 1; attempt <= 3; attempt++) {
    created = await run("hdiutil", [...createSpec]);
    if (created.code === 0) break;
    // CI (macos-26-arm64) reports "No space left on device" from hdiutil with ~90Gi free on
    // /; df in the same step only shows the system slice, so the free space of the Data
    // volume is printed before the step ends and every failure is loud, in order. Healthy
    // runners succeed on the first try; an unhealthy VM keeps failing at any pause, so
    // three tries with a growing pause cover the recoverable cases and the failed job is
    // then rerun, which schedules a fresh VM (see docs/DECISIONS.md 149).
    if (attempt < 3) {
      const wait = attempt === 1 ? 10000 : 45000;
      console.error(`hdiutil create failed (attempt ${attempt}), retrying after ${wait / 1000}s: ${created.stderr.trim()}`);
      await new Promise((resolve) => setTimeout(resolve, wait));
    }
  }
  if (created!.code !== 0) fail(`hdiutil create failed: ${created!.stderr.trim()}`);

  const verified = await run("hdiutil", ["verify", DMG]);
  if (verified.code !== 0) fail(`hdiutil verify rejected the image: ${verified.stderr.trim()}`);

  const info = await run("hdiutil", ["imageinfo", DMG]);
  if (info.code !== 0) fail(`hdiutil imageinfo failed: ${info.stderr.trim()}`);
  const total = Number(/Total Bytes:\s*(\d+)/.exec(`${info.stdout}\n${info.stderr}`)?.[1] ?? "0");
  if (!Number.isFinite(total) || total <= 0) fail("hdiutil imageinfo did not report the size of the image");
  if (total < stagedBytes) fail(`the image holds ${total} bytes but the app alone is ${stagedBytes}`);
  if (total > stagedBytes * 2) fail(`the image is ${total} bytes for ${stagedBytes} bytes of content`);

  const imageBytes = (await stat(DMG)).size;
  if (imageBytes <= 0) fail(`the image ${DMG} is empty`);
  if (imageBytes > total) fail(`the image file is ${imageBytes} bytes, larger than the ${total} bytes it holds`);

  const attached = await run("hdiutil", ["attach", DMG, "-nobrowse", "-readonly"]);
  if (attached.code !== 0) fail(`hdiutil attach failed: ${attached.stderr.trim()}`);
  const { device, mountPoint } = parseAttach(attached.stdout);
  if (!mountPoint) fail(`hdiutil attach did not report a mount point: ${attached.stdout.trim()}`);
  const volumeName = basename(mountPoint).split(" ")[0] ?? "";
  if (volumeName !== VOLUME) fail(`the image mounted as "${volumeName}", it must be "${VOLUME}"`);

  try {
    const mountedApp = join(mountPoint, "Dustless.app");
    if (!existsSync(mountedApp)) fail(`the mounted image holds no Dustless.app (${mountPoint})`);
    const mountedLink = join(mountPoint, "Applications");
    if (!existsSync(mountedLink)) fail(`the mounted image holds no Applications symlink (${mountPoint})`);
    const target = await readlink(mountedLink).catch(() => null);
    if (target !== "/Applications") fail(`the Applications entry in the image points at "${target}"`);
    const mountedExecutable = join(mountedApp, "Contents", "MacOS", "Dustless");
    if (!existsSync(mountedExecutable)) fail(`the mounted image holds no app executable (${mountPoint})`);
    const mountedSignature = await run("codesign", ["--verify", "--deep", mountedApp]);
    if (mountedSignature.code !== 0) fail(`the app in the image is not signed: ${mountedSignature.stderr.trim()}`);
    const mountedVersion = await run(join(mountedApp, "Contents", "Resources", "dustless"), ["version"]);
    if (mountedVersion.code !== 0) fail(`the engine in the image did not answer \`version\`: ${mountedVersion.stderr.trim()}`);
    if (mountedVersion.stdout.trim() !== version) {
      fail(`the engine in the image reports ${mountedVersion.stdout.trim()} but the release is ${version}`);
    }
    const tree = await run("ls", ["-R", mountPoint]);
    if (tree.code !== 0) fail(`could not list the mounted image: ${tree.stderr.trim()}`);
    process.stdout.write(`${tree.stdout}\n`);
    process.stdout.write(`volume ${VOLUME} mounted at ${mountPoint} on ${device ?? "an unknown device"}\n`);
  } finally {
    const detached = await run("hdiutil", ["detach", mountPoint]);
    if (detached.code !== 0) fail(`hdiutil detach failed: ${detached.stderr.trim()}`);
  }

  console.log(
    `done ${DMG} in ${((Date.now() - started) / 1000).toFixed(1)}s ` +
      `(volume ${VOLUME}, ${stagedBytes} bytes of content, ${total} bytes of image, ${imageBytes} bytes on disk)`,
  );
} finally {
  await rm(stage, { recursive: true, force: true }).catch(() => undefined);
}
