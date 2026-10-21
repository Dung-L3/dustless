import { copyFile, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DIST, ROOT, fail, readVersion, run, runInherit } from "./lib.ts";

const version = await readVersion();
const EXE = join(DIST, "dustless.exe");
const ZIP = join(DIST, `dustless-${version}-windows-x64.zip`);

function readmeText(): string {
  return `Dustless v${version} — Windows (x64) portable build
================================================

A single, self-contained executable. It needs no Bun, Node.js, or any
entry on PATH — the runtime is embedded in the binary.

To use:
  1. Unzip this archive anywhere (for example C:\\Tools\\Dustless).
  2. Open PowerShell or cmd in that folder.
  3. Run:

       .\\dustless.exe scan
       .\\dustless.exe doctor
       .\\dustless.exe help

  Add the folder to your PATH to call \`dustless\` from any directory.

First-launch note:
  This build is unsigned (produced locally without a code-signing
  certificate), so Windows SmartScreen may show "Windows protected your
  PC". Click "More info", then "Run anyway". It is the same binary the
  project's CI release workflow produces on windows-latest.
`;
}

const started = Date.now();

const built = await runInherit(process.execPath, ["scripts/build.ts"], {
  cwd: ROOT,
  env: { ...process.env, BUN_TARGET: "bun-windows-x64", OUTFILE: EXE },
});
if (built !== 0) fail("windows cross-compile failed");

const inspected = await run("file", [EXE]);
if (inspected.code !== 0 || !/PE32\+/.test(inspected.stdout)) {
  fail(`not a PE32+ executable: ${inspected.stdout}${inspected.stderr}`);
}

const strings = await run("strings", ["-a", EXE]);
const imports = [...new Set(strings.stdout.match(/^[A-Za-z0-9_.-]+\.dll$/gm) ?? [])];
const suspicious = imports.filter((name) => /bun|node|libuv|libnode|vcruntime|msvcp/i.test(name));
if (suspicious.length > 0) fail(`binary depends on an external runtime: ${suspicious.join(", ")}`);
console.log(
  `self-contained check passed: ${imports.length} imports, all Windows system DLLs (no Bun/Node runtime)`,
);
console.log(`  ${imports.join(", ")}`);

const stage = await mkdtemp(join(tmpdir(), "dustless-win-"));
try {
  await copyFile(EXE, join(stage, "dustless.exe"));
  await writeFile(join(stage, "README.txt"), readmeText());
  await rm(ZIP, { force: true });
  const zipped = await run("tar", ["-a", "-c", "-f", ZIP, "dustless.exe", "README.txt"], { cwd: stage });
  if (zipped.code !== 0) fail(`the portable archive failed: ${zipped.stderr.trim()}`);
  console.log(`done ${ZIP} in ${((Date.now() - started) / 1000).toFixed(1)}s`);
} finally {
  await rm(stage, { recursive: true, force: true }).catch(() => undefined);
}
