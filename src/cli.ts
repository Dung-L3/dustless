#!/usr/bin/env bun
import { runRam } from "./core/ram/index.ts";
import { serveMcp } from "./mcp/server.ts";
import { args, errorOut, fail, flag, flushStdout, HELP, unknownFlag, VERSION } from "./cli/context.ts";
import { runDoctor } from "./cli/doctor.ts";
import { runAwdl, runNet } from "./cli/net.ts";
import { runRule } from "./cli/rule.ts";
import { runApply, runScan } from "./cli/scan.ts";
import { runApps, runLargeFiles } from "./cli/storage.ts";

async function main(): Promise<number> {
  if (flag("version")) {
    console.log(flag("json") ? JSON.stringify({ version: VERSION }) : VERSION);
    return 0;
  }
  if (flag("help")) {
    console.log(HELP);
    return 0;
  }
  const [command = "help", ...rest] = args.positional;
  const unknown = unknownFlag(command);
  if (unknown) return await fail(`unknown flag ${unknown} for ${command} — chạy \`dustless help\``);
  if (command === "scan") return await runScan();
  if (command === "apply") return await runApply();
  if (command === "rule") return await runRule(rest[0] ?? "", rest.slice(1));
  if (command === "doctor") return await runDoctor();
  if (command === "net") return await runNet();
  if (command === "awdl") return await runAwdl();
  if (command === "mcp") {
    await serveMcp();
    return 0;
  }
  if (command === "ram") return await runRam();
  if (command === "apps") return await runApps(rest);
  if (command === "largefiles") return await runLargeFiles();
  if (command === "version") {
    console.log(flag("json") ? JSON.stringify({ version: VERSION }) : VERSION);
    return 0;
  }
  if (command === "help" || flag("help")) {
    console.log(HELP);
    return 0;
  }
  throw new Error(`lệnh không hợp lệ "${command}" — chạy \`dustless help\``);
}

process.on("unhandledRejection", (reason) => {
  errorOut(String(reason));
  void flushStdout().finally(() => process.exit(1));
});

main().then(
  async (code) => {
    await flushStdout();
    process.exitCode = code;
  },
  async (err: Error) => {
    await fail(err.message);
    await flushStdout();
    process.exitCode = 1;
  },
);
