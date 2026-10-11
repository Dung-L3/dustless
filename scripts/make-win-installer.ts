import { mkdir, readFile, stat } from "node:fs/promises";
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";

const REPO = join(import.meta.dir, "..");
const pkg = JSON.parse(await readFile(join(REPO, "package.json"), "utf8")) as { version: string };
const version = pkg.version;

const engine = process.env["ENGINE_EXE"] ?? join(REPO, "dist", "dustless.exe");
const icon = process.env["ICON_FILE"] ?? (await firstExisting([
  join(REPO, "dist", "icons", "dustless.ico"),
  join(REPO, "brand", "generated", "dustless.ico"),
]));
const script = join(REPO, "packaging", "windows", "installer.nsi");
const outfile = join(REPO, "dist", `Dustless-${version}-setup.exe`);

async function firstExisting(paths: string[]): Promise<string> {
  for (const path of paths) {
    try {
      if ((await stat(path)).size > 0) return path;
    } catch {
      continue;
    }
  }
  return paths[0] ?? "";
}

async function require(path: string, what: string): Promise<void> {
  try {
    const info = await stat(path);
    if (info.size === 0) throw new Error("empty");
  } catch {
    throw new Error(`${what} missing at ${path}. Build it first.`);
  }
}

await require(engine, "engine binary");
await require(icon, "icon");

const [major = 0, minor = 0, patch = 0] = version.split(".").map(Number);
const version4 = `${major}.${minor}.${patch}.0`;

await mkdir(dirname(outfile), { recursive: true });

const makensis = process.env["MAKENSIS"] ?? "makensis";
const args = [
  `/DAPP_VERSION=${version}`,
  `/DAPP_VERSION4=${version4}`,
  `/DENGINE_EXE=${engine}`,
  `/DICON_FILE=${icon}`,
  `/DOUTPUT_EXE=${outfile}`,
  script,
];

const code = await new Promise<number>((resolve) => {
  spawn(makensis, args, { stdio: "inherit" }).on("close", (c) => resolve(c ?? 1));
});

if (code !== 0) {
  console.error(`makensis exited ${code}`);
  process.exit(code);
}

const built = await stat(outfile);
console.log(`installer written: ${outfile} (${(built.size / 1048576).toFixed(1)} MB)`);