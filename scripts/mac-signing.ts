import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { mkdtemp, open, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fail, run } from "./lib.ts";

export const CERT_ENV = "MACOS_SIGNING_CERT";
export const CERT_PASSWORD_ENV = "MACOS_SIGNING_CERT_PASSWORD";
export const IDENTITY_ENV = "MACOS_SIGNING_IDENTITY";
export const SIGN_MODE_ENV = "DUSTLESS_SIGN_MODE";
export const DEVELOPER_ID = "Developer ID Application:";
export const NOTARY_VARS = [
  "MACOS_NOTARY_PROFILE",
  "MACOS_NOTARY_KEY_ID",
  "MACOS_NOTARY_KEY",
  "MACOS_NOTARY_ISSUER_ID",
  "MACOS_NOTARY_APPLE_ID",
  "MACOS_NOTARY_PASSWORD",
  "MACOS_NOTARY_TEAM_ID",
];

export type SignatureKind = "adhoc" | "developer-id";

export type SigningPlan = {
  kind: SignatureKind;
  identity: string | null;
  finish: () => Promise<void>;
};

export type NotaryCredentials = {
  args: string[];
  source: string;
  finish: () => Promise<void>;
};

export type SignatureInfo = {
  kind: SignatureKind;
  authority: string | null;
  team: string | null;
};

export async function sha256(path: string): Promise<string> {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) hash.update(chunk as Buffer);
  return hash.digest("hex");
}

export async function isMachO(path: string): Promise<boolean> {
  const handle = await open(path, "r");
  try {
    const buffer = Buffer.alloc(4);
    const { bytesRead } = await handle.read(buffer, 0, 4, 0);
    if (bytesRead < 4) return false;
    const magic = buffer.readUInt32BE(0);
    return magic === 0xfeedface || magic === 0xfeedfacf || magic === 0xcefaedfe || magic === 0xcffaedfe;
  } finally {
    await handle.close();
  }
}

export async function architectures(path: string): Promise<string> {
  const info = await run("lipo", ["-archs", path]);
  if (info.code !== 0) fail(`could not read the architecture of ${path}: ${info.stderr.trim()}`);
  return info.stdout.trim();
}

export async function nestedCodePaths(app: string): Promise<string[]> {
  const found: string[] = [];
  const walk = async (dir: string): Promise<void> => {
    const entries = await readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(full);
        continue;
      }
      if (!entry.isFile()) continue;
      if (await isMachO(full)) found.push(full);
    }
  };
  await walk(join(app, "Contents"));
  return found.sort();
}

export async function developerIdIdentities(): Promise<string[]> {
  const found = await run("security", ["find-identity", "-v", "-p", "codesigning"]);
  const text = `${found.stdout}\n${found.stderr}`;
  return [...text.matchAll(/^\s*\d+\)\s+[0-9A-F]{40}\s+"(.+)"\s*$/gm)]
    .map((match) => match[1] ?? "")
    .filter((name) => name.startsWith(DEVELOPER_ID));
}

function pickIdentity(identities: string[], wanted: string | undefined): string | null {
  if (wanted) {
    return identities.find((name) => name === wanted) ?? identities.find((name) => name.includes(wanted)) ?? null;
  }
  return identities[0] ?? null;
}

async function importCertificate(cert: string, password: string): Promise<{ identities: string[]; finish: () => Promise<void> }> {
  const dir = await mkdtemp(join(tmpdir(), "dustless-signing-"));
  const keychain = join(dir, "signing.keychain-db");
  const file = join(dir, "certificate.p12");
  await writeFile(file, Buffer.from(cert.replace(/\s+/g, ""), "base64"));
  const listed = await run("security", ["list-keychains", "-d", "user"]);
  const original = listed.stdout.split("\n").map((line) => line.trim()).filter(Boolean);
  const finish = async (): Promise<void> => {
    await run("security", ["list-keychains", "-d", "user", "-s", ...original]);
    await rm(dir, { recursive: true, force: true });
  };
  const created = await run("security", ["create-keychain", "-p", password, keychain]);
  if (created.code !== 0) {
    await finish();
    fail(`could not create the signing keychain: ${created.stderr.trim()}`);
  }
  await run("security", ["set-keychain-settings", "-lut", "21600", keychain]);
  const unlocked = await run("security", ["unlock-keychain", "-p", password, keychain]);
  if (unlocked.code !== 0) {
    await finish();
    fail(`could not unlock the signing keychain: ${unlocked.stderr.trim()}`);
  }
  const imported = await run("security", ["import", file, "-P", password, "-A", "-f", "pkcs12", "-k", keychain]);
  if (imported.code !== 0) {
    await finish();
    fail(`could not import the Developer ID certificate: ${imported.stderr.trim()}`);
  }
  const partitioned = await run("security", ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, keychain]);
  if (partitioned.code !== 0) {
    await finish();
    fail(`codesign may not use the private key without a prompt: ${partitioned.stderr.trim()}`);
  }
  await run("security", ["list-keychains", "-d", "user", "-s", ...original, keychain]);
  return { identities: await developerIdIdentities(), finish };
}

export async function resolveSigning(): Promise<SigningPlan> {
  const mode = (process.env[SIGN_MODE_ENV] ?? "auto").trim();
  if (mode !== "auto" && mode !== "adhoc" && mode !== "developer-id") {
    fail(`${SIGN_MODE_ENV} must be auto, adhoc or developer-id, got "${mode}"`);
  }
  const cert = process.env[CERT_ENV]?.trim();
  const password = process.env[CERT_PASSWORD_ENV];
  const wanted = process.env[IDENTITY_ENV]?.trim();
  if (mode === "adhoc") {
    if (cert && password) {
      process.stderr.write(`${SIGN_MODE_ENV}=adhoc: the Developer ID certificate is ignored on purpose\n`);
    }
    return { kind: "adhoc", identity: null, finish: async () => undefined };
  }
  if (cert && !password) fail(`${CERT_ENV} is set but ${CERT_PASSWORD_ENV} is missing`);
  if (cert && password) {
    const imported = await importCertificate(cert, password);
    const identity = pickIdentity(imported.identities, wanted);
    if (!identity) {
      await imported.finish();
      fail(
        `the certificate holds no "Developer ID Application" identity${wanted ? ` named "${wanted}"` : ""}` +
          ` — the keychain holds: ${imported.identities.join(", ") || "nothing"}`,
      );
    }
    return { kind: "developer-id", identity, finish: imported.finish };
  }
  if (wanted) {
    const identities = await developerIdIdentities();
    const identity = pickIdentity(identities, wanted);
    if (!identity) fail(`the keychain holds no Developer ID identity named "${wanted}"`);
    return { kind: "developer-id", identity, finish: async () => undefined };
  }
  if (mode === "developer-id") {
    fail(`${SIGN_MODE_ENV}=developer-id needs ${CERT_ENV} and ${CERT_PASSWORD_ENV} in the environment`);
  }
  return { kind: "adhoc", identity: null, finish: async () => undefined };
}

export async function signApplication(app: string, plan: SigningPlan): Promise<void> {
  try {
    if (plan.kind === "adhoc") {
      const adhoc = await run("codesign", ["--force", "--deep", "--sign", "-", app]);
      if (adhoc.code !== 0) fail(`the ad-hoc signature failed: ${adhoc.stderr.trim()}`);
      const verified = await run("codesign", ["--verify", "--deep", app]);
      if (verified.code !== 0) fail(`codesign --verify failed: ${verified.stderr.trim()}`);
      return;
    }
    const identity = plan.identity;
    if (!identity) fail("there is no Developer ID identity to sign with");
    for (const nested of await nestedCodePaths(app)) {
      const signed = await run("codesign", ["--force", "--options", "runtime", "--timestamp", "--sign", identity, nested]);
      if (signed.code !== 0) fail(`codesign failed for ${nested}: ${signed.stderr.trim()}`);
    }
    const signed = await run("codesign", ["--force", "--options", "runtime", "--timestamp", "--sign", identity, app]);
    if (signed.code !== 0) fail(`codesign failed: ${signed.stderr.trim()}`);
    const verified = await run("codesign", ["--verify", "--deep", "--strict", app]);
    if (verified.code !== 0) fail(`codesign --verify failed: ${verified.stderr.trim()}`);
  } finally {
    await plan.finish();
  }
}

export async function inspectSignature(app: string): Promise<SignatureInfo> {
  const shown = await run("codesign", ["-dv", "--verbose=4", app]);
  const text = `${shown.stdout}\n${shown.stderr}`;
  const authority = /Authority=([^\n]+)/.exec(text)?.[1]?.trim() ?? null;
  const team = /TeamIdentifier=([^\n]+)/.exec(text)?.[1]?.trim() ?? null;
  const adhoc = /Signature=adhoc/.test(text) || authority === null || authority === "not set";
  return { kind: adhoc ? "adhoc" : "developer-id", authority: adhoc ? null : authority, team: adhoc ? null : team };
}

export async function resolveNotaryCredentials(): Promise<NotaryCredentials | null> {
  const profile = process.env["MACOS_NOTARY_PROFILE"]?.trim();
  if (profile) {
    return { args: ["--keychain-profile", profile], source: `MACOS_NOTARY_PROFILE=${profile}`, finish: async () => undefined };
  }
  const keyId = process.env["MACOS_NOTARY_KEY_ID"]?.trim();
  const key = process.env["MACOS_NOTARY_KEY"];
  const issuer = process.env["MACOS_NOTARY_ISSUER_ID"]?.trim();
  if (keyId && key && issuer) {
    const dir = await mkdtemp(join(tmpdir(), "dustless-notary-"));
    const file = join(dir, "AuthKey.p8");
    const body = key.includes("BEGIN PRIVATE KEY")
      ? key
      : Buffer.from(key.replace(/\s+/g, ""), "base64").toString("utf8");
    await writeFile(file, body, { mode: 0o600 });
    return {
      args: ["--key", file, "--key-id", keyId, "--issuer", issuer],
      source: "MACOS_NOTARY_KEY_ID, MACOS_NOTARY_KEY and MACOS_NOTARY_ISSUER_ID",
      finish: async () => {
        await rm(dir, { recursive: true, force: true });
      },
    };
  }
  const appleId = process.env["MACOS_NOTARY_APPLE_ID"]?.trim();
  const password = process.env["MACOS_NOTARY_PASSWORD"];
  const teamId = process.env["MACOS_NOTARY_TEAM_ID"]?.trim();
  if (appleId && password && teamId) {
    return {
      args: ["--apple-id", appleId, "--password", password, "--team-id", teamId],
      source: "MACOS_NOTARY_APPLE_ID, MACOS_NOTARY_PASSWORD and MACOS_NOTARY_TEAM_ID",
      finish: async () => undefined,
    };
  }
  return null;
}
