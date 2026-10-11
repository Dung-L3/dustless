import { ROOT, runInherit } from "./lib.ts";

const steps = ["build", "bundle:mac", "dmg", "package:win"];

const results: string[] = [];
for (const script of steps) {
  const code = await runInherit(process.execPath, ["run", script], { cwd: ROOT });
  results.push(`${code === 0 ? "ok  " : "FAIL"} ${script}`);
}

console.log(`\npackage summary:\n${results.map((line) => `  ${line}`).join("\n")}`);
process.exitCode = results.every((line) => line.startsWith("ok")) ? 0 : 1;
