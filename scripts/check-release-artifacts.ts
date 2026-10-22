import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { DIST, ROOT, fail, run } from "./lib.ts";

const tag = process.argv[2] ?? "";
const withArtifacts = process.argv.includes("--artifacts");
const BUNDLE_ID = "dev.dustless.mac";
const VERSION_FREE = [
  "packaging/windows/installer.nsi",
  "scripts/bundle-macos.ts",
  "scripts/make-dmg.ts",
  "scripts/make-win-installer.ts",
  "scripts/package-win.ts",
];
const READMES = [
  { file: "README.md", token: /version/i },
  { file: "README.vi.md", token: /phiên bản/i },
  { file: "README.zh.md", token: /版本/ },
];

if (!/^v\d+\.\d+\.\d+$/.test(tag)) {
  fail(`release tag must look like v1.2.3, got "${tag}"`);
}
const version = tag.replace(/^v/, "");
const escaped = version.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const problems: string[] = [];

const pkg = JSON.parse(await readFile(join(ROOT, "package.json"), "utf8")) as { version: string };
if (pkg.version !== version) problems.push(`package.json is ${pkg.version} but the tag says ${version}`);

const changelog = await readFile(join(ROOT, "CHANGELOG.md"), "utf8");
if (!new RegExp(`^## .*${escaped}`, "m").test(changelog)) {
  problems.push(`CHANGELOG.md has no heading for ${version}`);
}

for (const readme of READMES) {
  const text = await readFile(join(ROOT, readme.file), "utf8");
  const lines = text.split("\n");
  const first = lines.find((candidate) => readme.token.test(candidate));
  if (!first) {
    problems.push(`${readme.file} never says which version it is`);
    continue;
  }
  const named = /\b\d+\.\d+\.\d+\b/.exec(first)?.[0];
  if (named !== version) {
    problems.push(`${readme.file} says the version is ${named ?? "unknown"} but the release is ${version}`);
  }
}

for (const file of VERSION_FREE) {
  const path = join(ROOT, file);
  if (!existsSync(path)) continue;
  const text = await readFile(path, "utf8");
  const literal = /\b\d+\.\d+\.\d+\b/.exec(text)?.[0];
  if (literal) problems.push(`${file} hardcodes the version ${literal} instead of reading it from package.json`);
}

if (withArtifacts) {
  const engine = process.env["DUSTLESS_ENGINE"] ?? join(DIST, "dustless");
  if (!existsSync(engine)) problems.push(`${engine} is missing — build it before checking the release`);
  else {
    const reported = await run(engine, ["version"]);
    if (reported.code !== 0) problems.push(`${engine} did not answer \`version\`: ${reported.stderr.trim()}`);
    else if (reported.stdout.trim() !== version) {
      problems.push(`${engine} prints ${reported.stdout.trim()} but the tag says ${version}`);
    }
  }

  const app = join(DIST, "Dustless.app");
  const plist = join(app, "Contents", "Info.plist");
  if (!existsSync(plist)) problems.push(`${plist} is missing — build the bundle before checking the release`);
  else {
    const shown = await run("plutil", ["-p", plist]);
    if (shown.code !== 0) problems.push(`${plist} could not be read: ${shown.stderr.trim()}`);
    else {
      const text = shown.stdout;
      if (!text.includes(`"${version}"`)) problems.push(`Info.plist does not carry the version ${version}`);
      if (!text.includes(`"${BUNDLE_ID}"`)) problems.push(`Info.plist does not carry ${BUNDLE_ID}`);
      if (/LSUIElement/.test(text)) problems.push("Info.plist carries LSUIElement, the app must stay a normal application");
    }
  }

  const bundled = join(app, "Contents", "Resources", "dustless");
  if (!existsSync(bundled)) problems.push(`${bundled} is missing`);
  else {
    const reported = await run(bundled, ["version"]);
    if (reported.code !== 0) problems.push(`the bundled engine did not answer \`version\`: ${reported.stderr.trim()}`);
    else if (reported.stdout.trim() !== version) {
      problems.push(`the bundled engine prints ${reported.stdout.trim()} but the tag says ${version}`);
    }
  }

  const dmg = join(DIST, `Dustless-${version}.dmg`);
  if (!existsSync(dmg)) problems.push(`${dmg} is missing`);
}

if (problems.length > 0) {
  for (const problem of problems) process.stderr.write(`${problem}\n`);
  process.stderr.write(`${problems.length} release consistency problem(s)\n`);
  process.exit(1);
}

process.stdout.write(
  `release ${tag} agrees with package.json, CHANGELOG.md and the three READMEs` +
    (withArtifacts ? ", the engine, the app bundle and the disk image" : "") +
    "\n",
);
