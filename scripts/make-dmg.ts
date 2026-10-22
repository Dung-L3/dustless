import { lstat, mkdtemp, readdir, readlink, rm, stat, symlink } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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

function blockForHfs(stdout: string): { device: string | null; label: string | null } {
  const rows = stdout.split("\n").filter((line) => line.startsWith("/dev/disk"));
  if (rows.length === 0) return { device: null, label: null };
  const hfs = rows.filter((row) => row.split(/\s+/)[1]?.includes("HFS"));
  const picked = (hfs.length > 0 ? hfs[hfs.length - 1] : rows[rows.length - 1])!;
  const fields = picked.split(/\s+/).filter(Boolean);
  return { device: fields[0] ?? null, label: fields[2] ?? null };
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
  const sourceHash = await sha256(join(APP, "Contents", "Resources", "dustless"));

  const stagedBytes = await treeBytes(stage);
  if (stagedBytes <= 0) fail("the staging folder is empty");

  const sizeMb = Math.ceil((stagedBytes + 96 * 1024 * 1024) / (1024 * 1024));
  const rw = join(stage, "dustless-rw.dmg");
  const created = await run("hdiutil", ["create", rw, "-volname", VOLUME, "-size", `${sizeMb}m`, "-fs", "HFS+"]);
  if (created.code !== 0) fail(`hdiutil create of the staging image failed: ${created.stderr.trim()}`);

  const attachedRaw = await run("hdiutil", ["attach", rw, "-nobrowse", "-nomount"]);
  if (attachedRaw.code !== 0) fail(`hdiutil attach (staging image) failed: ${attachedRaw.stderr.trim()}`);
  process.stdout.write(`staging attach -nomount: ${attachedRaw.stdout.trim().split("\n").join(" | ")}\n`);
  const raw = blockForHfs(attachedRaw.stdout);
  if (raw.device === null) fail(`hdiutil attach -nomount did not report a device: ${attachedRaw.stdout.trim()}`);
  if (raw.label !== null && raw.label !== VOLUME) fail(`the staging image labels itself ${raw.label}, it must be ${VOLUME}`);

  const mountPoint = await mkdtemp(join(tmpdir(), "dustless-mnt-"));
  const mounted = await run("sudo", ["mount", "-t", "hfs", raw.device, mountPoint]);
  if (mounted.code !== 0) fail(`mount -t hfs ${raw.device} failed: ${mounted.stderr.trim()}`);

  const putApp = await run("sudo", ["ditto", APP, join(mountPoint, "Dustless.app")]);
  if (putApp.code !== 0) fail(`ditto into the image failed: ${putApp.stderr.trim()}`);
  const putLink = await run("sudo", ["ln", "-s", "/Applications", join(mountPoint, "Applications")]);
  if (putLink.code !== 0) fail(`the Applications link failed: ${putLink.stderr.trim()}`);

  const imageApp = join(mountPoint, "Dustless.app");
  const imageSignature = await run("codesign", ["--verify", "--deep", imageApp]);
  if (imageSignature.code !== 0) fail(`the app copied into the image is not signed: ${imageSignature.stderr.trim()}`);
  const imageHash = await sha256(join(imageApp, "Contents", "Resources", "dustless"));
  if (imageHash !== sourceHash) fail("the engine copied into the image is not the engine that was bundled");
  const imageVersion = await run(join(imageApp, "Contents", "Resources", "dustless"), ["version"]);
  if (imageVersion.code !== 0) fail(`the engine in the image did not answer \`version\`: ${imageVersion.stderr.trim()}`);
  if (imageVersion.stdout.trim() !== version) {
    fail(`the engine in the image reports ${imageVersion.stdout.trim()} but the release is ${version}`);
  }

  const unmounted = await run("sudo", ["umount", mountPoint]);
  await rm(mountPoint, { recursive: true, force: true }).catch(() => undefined);
  if (unmounted.code !== 0) fail(`umount failed: ${unmounted.stderr.trim()}`);
  const detached = await run("hdiutil", ["detach", raw.device]);
  if (detached.code !== 0) fail(`hdiutil detach (staging image) failed: ${detached.stderr.trim()}`);

  await rm(DMG, { force: true }).catch(() => undefined);
  const converted = await run("hdiutil", ["convert", rw, "-format", "UDZO", "-o", DMG]);
  if (converted.code !== 0) fail(`hdiutil convert failed: ${converted.stderr.trim()}`);

  const verified = await run("hdiutil", ["verify", DMG]);
  if (verified.code !== 0) fail(`hdiutil verify rejected the image: ${verified.stderr.trim()}`);

  const info = await run("hdiutil", ["imageinfo", DMG]);
  if (info.code !== 0) fail(`hdiutil imageinfo failed: ${info.stderr.trim()}`);
  const total = Number(/Total Bytes:\s*(\d+)/.exec(`${info.stdout}\n${info.stderr}`)?.[1] ?? "0");
  if (!Number.isFinite(total) || total <= 0) fail("hdiutil imageinfo did not report the size of the image");
  if (total < stagedBytes) fail(`the image holds ${total} bytes but the app alone is ${stagedBytes}`);
  if (total > sizeMb * 1024 * 1024 * 1.05) {
    fail(`the image holds ${total} bytes for an image of ${sizeMb} MiB`);
  }

  const imageBytes = (await stat(DMG)).size;
  if (imageBytes <= 0) fail(`the image ${DMG} is empty`);
  if (imageBytes > total) fail(`the image file is ${imageBytes} bytes, larger than the ${total} bytes it holds`);

  const checkAttach = await run("hdiutil", ["attach", DMG, "-nobrowse", "-nomount"]);
  if (checkAttach.code !== 0) fail(`hdiutil attach (final image) failed: ${checkAttach.stderr.trim()}`);
  process.stdout.write(`final attach -nomount: ${checkAttach.stdout.trim().split("\n").join(" | ")}\n`);
  const check = blockForHfs(checkAttach.stdout);
  if (check.device === null) fail(`hdiutil attach -nomount did not report a device: ${checkAttach.stdout.trim()}`);
  if (check.label !== null && check.label !== VOLUME) fail(`the image labels itself ${check.label}, it must be ${VOLUME}`);

  const checkMount = await mkdtemp(join(tmpdir(), "dustless-check-"));
  const readOnly = await run("sudo", ["mount", "-r", "-t", "hfs", check.device, checkMount]);
  if (readOnly.code !== 0) fail(`mount -r -t hfs ${check.device} failed: ${readOnly.stderr.trim()}`);

  const mountedApp = join(checkMount, "Dustless.app");
  if (!existsSync(mountedApp)) fail(`the mounted image holds no Dustless.app (${checkMount})`);
  const mountedLink = join(checkMount, "Applications");
  if (!existsSync(mountedLink)) fail(`the mounted image holds no Applications symlink (${checkMount})`);
  const target = await readlink(mountedLink).catch(() => null);
  if (target !== "/Applications") fail(`the Applications entry in the image points at "${target}"`);
  const mountedExecutable = join(mountedApp, "Contents", "MacOS", "Dustless");
  if (!existsSync(mountedExecutable)) fail(`the mounted image holds no app executable (${checkMount})`);
  const mountedSignature = await run("codesign", ["--verify", "--deep", mountedApp]);
  if (mountedSignature.code !== 0) fail(`the app in the image is not signed: ${mountedSignature.stderr.trim()}`);
  const mountedVersion = await run(join(mountedApp, "Contents", "Resources", "dustless"), ["version"]);
  if (mountedVersion.code !== 0) fail(`the engine in the image did not answer \`version\`: ${mountedVersion.stderr.trim()}`);
  if (mountedVersion.stdout.trim() !== version) {
    fail(`the engine in the image reports ${mountedVersion.stdout.trim()} but the release is ${version}`);
  }
  const tree = await run("ls", ["-R", checkMount]);
  if (tree.code !== 0) fail(`could not list the mounted image: ${tree.stderr.trim()}`);
  process.stdout.write(`${tree.stdout}\n`);
  process.stdout.write(`volume ${VOLUME} mounted read only from ${check.device}\n`);

  const readUnmounted = await run("sudo", ["umount", checkMount]);
  await rm(checkMount, { recursive: true, force: true }).catch(() => undefined);
  if (readUnmounted.code !== 0) fail(`umount failed: ${readUnmounted.stderr.trim()}`);
  const readDetached = await run("hdiutil", ["detach", check.device]);
  if (readDetached.code !== 0) fail(`hdiutil detach (final image) failed: ${readDetached.stderr.trim()}`);

  console.log(
    `done ${DMG} in ${((Date.now() - started) / 1000).toFixed(1)}s ` +
      `(${stagedBytes} bytes of content, ${total} bytes of image, ${imageBytes} bytes on disk)`,
  );
} finally {
  await rm(stage, { recursive: true, force: true }).catch(() => undefined);
}
