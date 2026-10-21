import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { ROOT } from "./lib.ts";

const tag = process.argv[2] ?? "";
if (!/^v\d+\.\d+\.\d+/.test(tag)) {
  process.stderr.write(`release tag must look like v1.2.3, got "${tag}"\n`);
  process.exit(1);
}
const version = tag.replace(/^v/, "");

const problems: string[] = [];

const pkg = JSON.parse(await readFile(join(ROOT, "package.json"), "utf8")) as { version: string };
if (pkg.version !== version) {
  problems.push(`package.json is ${pkg.version} but the tag says ${version}`);
}

const changelog = await readFile(join(ROOT, "CHANGELOG.md"), "utf8");
const heading = new RegExp(`^## .*${version.replace(/\./g, "\\.")}`, "m");
if (!heading.test(changelog)) {
  problems.push(`CHANGELOG.md has no heading for ${version}`);
}

for (const readme of ["README.md", "README.vi.md", "README.zh.md"]) {
  const text = await readFile(join(ROOT, readme), "utf8");
  if (!text.includes(version)) problems.push(`${readme} never mentions ${version}`);
}

if (problems.length > 0) {
  for (const problem of problems) process.stderr.write(`${problem}\n`);
  process.exit(1);
}
process.stdout.write(`release ${tag} matches package.json, CHANGELOG.md and the three READMEs\n`);
