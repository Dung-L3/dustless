import { readFile, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { DIST, fail, readVersion, run } from "./lib.ts";
import { inspectSignature, NOTARY_VARS, resolveNotaryCredentials } from "./mac-signing.ts";

const APP = join(DIST, "Dustless.app");
const RECORD = join(DIST, "macos-release.json");
const version = await readVersion();
const DMG = join(DIST, `Dustless-${version}.dmg`);

if (!existsSync(join(APP, "Contents", "MacOS", "Dustless"))) {
  fail(`${APP} missing — run \`bun run bundle:mac\` first`);
}
if (!existsSync(DMG)) {
  fail(`${DMG} missing — run \`bun run dmg\` first`);
}

const record = JSON.parse(await readFile(RECORD, "utf8")) as {
  version: string;
  mode: string;
  identity: string | null;
  teamIdentifier: string | null;
  notarized: boolean;
  submissionId: string | null;
};
if (record.version !== version) fail(`the record says ${record.version} but the release is ${version}`);

const signature = await inspectSignature(APP);
if (signature.kind !== "developer-id") {
  fail(
    "the bundle is ad-hoc signed, so there is nothing to notarise" +
      " — sign it with a Developer ID first (MACOS_SIGNING_CERT and MACOS_SIGNING_CERT_PASSWORD)",
  );
}

const credentials = await resolveNotaryCredentials();
if (!credentials) {
  fail(
    "no notary credentials in the environment — set one of " +
      "MACOS_NOTARY_KEY_ID, MACOS_NOTARY_KEY and MACOS_NOTARY_ISSUER_ID, or " +
      "MACOS_NOTARY_APPLE_ID, MACOS_NOTARY_PASSWORD and MACOS_NOTARY_TEAM_ID, or MACOS_NOTARY_PROFILE" +
      ` (looked at ${NOTARY_VARS.join(", ")})`,
  );
}

const submitted = await run("xcrun", ["notarytool", "submit", DMG, ...credentials.args, "--wait"]);
if (submitted.code !== 0) {
  fail(`notarytool refused the image:\n${submitted.stdout.trim()}\n${submitted.stderr.trim()}`);
}
const submissionId = /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i.exec(
  `${submitted.stdout}\n${submitted.stderr}`,
)?.[1] ?? null;
if (!submissionId) {
  fail(`notarytool accepted the image but printed no submission id:\n${submitted.stdout.trim()}`);
}

for (const target of [DMG, APP]) {
  const stapled = await run("xcrun", ["stapler", "staple", target]);
  if (stapled.code !== 0) fail(`stapler could not staple ${target}: ${stapled.stderr.trim()}`);
}

for (const target of [APP, DMG]) {
  const validated = await run("xcrun", ["stapler", "validate", target]);
  if (validated.code !== 0) fail(`stapler validate rejected ${target}: ${validated.stderr.trim()}`);
}

const verified = await run("codesign", ["--verify", "--deep", "--strict", APP]);
if (verified.code !== 0) fail(`the signature broke while stapling: ${verified.stderr.trim()}`);

const accepted = await run("spctl", ["-a", "-t", "exec", "-v", APP]);
if (accepted.code !== 0) {
  fail(`Gatekeeper will not open the app: ${accepted.stdout.trim()} ${accepted.stderr.trim()}`);
}
const opened = await run("spctl", ["-a", "-t", "open", "--context", "context:primary-signature", "-v", DMG]);
if (opened.code !== 0) {
  fail(`Gatekeeper will not open the image: ${opened.stdout.trim()} ${opened.stderr.trim()}`);
}

record.notarized = true;
record.submissionId = submissionId;
record.identity = signature.authority;
record.teamIdentifier = signature.team;
await writeFile(RECORD, `${JSON.stringify(record, null, 2)}\n`);

console.log(`notarised ${DMG} (submission ${submissionId}) with ${signature.authority}`);
console.log(`stapled ticket on ${DMG} and ${APP}`);
console.log(`spctl accepted: ${accepted.stdout.trim()}`);
