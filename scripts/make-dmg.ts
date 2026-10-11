import { mkdtemp, rm, symlink } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DIST, fail, readVersion, run } from "./lib.ts";

const APP = join(DIST, "Dustless.app");
const version = await readVersion();
const DMG = join(DIST, `Dustless-${version}.dmg`);

if (!existsSync(join(APP, "Contents", "MacOS", "Dustless"))) {
  fail(`${APP} missing — run \`bun run bundle:mac\` first`);
}

const started = Date.now();
const stage = await mkdtemp(join(tmpdir(), "dustless-dmg-stage-"));
const mount = await mkdtemp(join(tmpdir(), "dustless-dmg-mount-"));

try {
  const copied = await run("ditto", [APP, join(stage, "Dustless.app")]);
  if (copied.code !== 0) fail(`ditto failed: ${copied.stderr.trim()}`);
  await symlink("/Applications", join(stage, "Applications"));

  const created = await run("hdiutil", [
    "create",
    "-volname",
    "Dustless",
    "-srcfolder",
    stage,
    "-ov",
    "-format",
    "UDZO",
    DMG,
  ]);
  if (created.code !== 0) fail(`hdiutil create failed: ${created.stderr.trim()}`);

  const attached = await run("hdiutil", [
    "attach",
    DMG,
    "-nobrowse",
    "-readonly",
    "-mountpoint",
    mount,
  ]);
  if (attached.code !== 0) fail(`hdiutil attach failed: ${attached.stderr.trim()}`);
  if (!existsSync(join(mount, "Dustless.app"))) {
    fail(`self-check failed: Dustless.app not present in mounted ${DMG}`);
  }
  if (!existsSync(join(mount, "Applications"))) {
    fail(`self-check failed: Applications symlink not present in mounted ${DMG}`);
  }

  const detached = await run("hdiutil", ["detach", mount]);
  if (detached.code !== 0) process.stderr.write(`warning: hdiutil detach failed: ${detached.stderr.trim()}\n`);

  console.log(`done ${DMG} in ${((Date.now() - started) / 1000).toFixed(1)}s (self-check passed)`);
} finally {
  await rm(stage, { recursive: true, force: true }).catch(() => undefined);
  await rm(mount, { recursive: true, force: true }).catch(() => undefined);
}
