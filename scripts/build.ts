import { mkdir } from "node:fs/promises";
import { spawn } from "node:child_process";
import { dirname } from "node:path";

const outfile = process.env["OUTFILE"] ?? "dist/dustless";
const target = process.env["BUN_TARGET"];
const minify = process.env["NO_MINIFY"] ? [] : ["--minify"];

await mkdir(dirname(outfile), { recursive: true });

const args = [
  "build",
  "--compile",
  ...minify,
  ...(target ? [`--target=${target}`] : []),
  `--outfile=${outfile}`,
  "src/cli.ts",
];

const code = await new Promise<number>((resolve) => {
  spawn(process.execPath, args, { stdio: "inherit" }).on("close", (c) => resolve(c ?? 1));
});

if (code === 0 && process.platform === "darwin" && !outfile.endsWith(".exe")) {
  await new Promise<void>((resolve) => {
    spawn("codesign", ["--force", "--sign", "-", outfile], { stdio: "inherit" }).on("close", () =>
      resolve(),
    );
  });
}

process.exit(code);