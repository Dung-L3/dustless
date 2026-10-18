import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { exec, sandbox, type Sandbox } from "./harness.ts";
import { currentPlatform } from "./harness.ts";

type AwdlReport = {
  platform: string;
  interface: string | null;
  state: "on" | "off" | "absent";
  changed: boolean;
  outcome: { status: string; detail: string } | null;
};

type AwdlPrivilege = { user: string; path: string; allowed: string[]; rule: string };

function reportOf(stdout: string): AwdlReport {
  return JSON.parse(stdout) as AwdlReport;
}

const IFCONFIG_FAKE = (log: string): string => `#!/bin/sh
echo "ifconfig $0 $*" >> "${log}"
exit 0
`;

const IFCONFIG_FAIL = (log: string): string => `#!/bin/sh
echo "ifconfig $0 $*" >> "${log}"
echo "ifconfig: awdl0: operation not permitted" >&2
exit 5
`;

const SUDO_PASS = (log: string, ifconfig: string): string => `#!/bin/sh
if [ "$1" != "-n" ]; then
  echo "sudo: only -n" >&2
  exit 1
fi
shift
echo "sudo -n $*" >> "${log}"
shift
exec "${ifconfig}" "$@"
`;

const SUDO_CONSENT = (log: string): string => `#!/bin/sh
if [ "$1" != "-n" ]; then
  echo "sudo: only -n" >&2
  exit 1
fi
shift
echo "sudo -n $*" >> "${log}"
echo "sudo: a password is required" >&2
exit 1
`;

async function installFakeIfconfig(
  home: string,
  variant: "pass" | "fail" | "consent",
): Promise<{ log: string; ifconfig: string }> {
  const bin = join(home, ".bin");
  await mkdir(bin, { recursive: true });
  const log = join(bin, "calls.log");
  const ifconfig = join(bin, "ifconfig.sh");
  const sudo = join(bin, "sudo");
  const body =
    variant === "fail" ? IFCONFIG_FAIL(log) : IFCONFIG_FAKE(log);
  await writeFile(ifconfig, body);
  await chmod(ifconfig, 0o755);
  await writeFile(sudo, variant === "consent" ? SUDO_CONSENT(log) : SUDO_PASS(log, ifconfig));
  await chmod(sudo, 0o755);
  return { log, ifconfig };
}

function envFor(home: string, ifconfig: string): Record<string, string> {
  return {
    PATH: `${join(home, ".bin")}:/usr/bin:/bin:/usr/sbin:/sbin`,
    HOME: home,
    USER: "e2etester",
    NO_COLOR: "1",
    TMPDIR: home,
    DUSTLESS_IFCONFIG: ifconfig,
  };
}

function arrange(lines: string[]): string[] {
  return lines.map((line) => line.trim()).filter((line) => line !== "");
}

function readLog(log: string): Promise<string> {
  return readFile(log, "utf8").catch(() => "");
}

function assertReportShape(run: { stdout: string }): void {
  const payload = reportOf(run.stdout);
  expect(Object.keys(payload).sort()).toEqual([
    "changed",
    "interface",
    "outcome",
    "platform",
    "state",
  ]);
}

describe("awdl status and privilege payloads (read-only) — macOS only", () => {
  let box: Sandbox;
  let log: string;
  let ifconfig: string;
  beforeAll(async () => {
    box = await sandbox("awdl-status");
    const installed = await installFakeIfconfig(box.home, "pass");
    log = installed.log;
    ifconfig = installed.ifconfig;
  });
  afterAll(async () => {
    await box.dispose();
  });

  test.skipIf(process.platform !== "darwin")("radio status reports the documented payload shape with no privilege command", async () => {
    const run = await exec(["awdl", "--json"], envFor(box.home, ifconfig));
    expect(run.code).toBe(0);
    expect(run.stderr).toBe("");
    assertReportShape(run);
    const payload = reportOf(run.stdout);
    expect(payload.platform).toBe("mac");
    expect(payload.interface).toBe("awdl0");
    expect(payload.changed).toBe(false);
    expect(payload.outcome).toBeNull();
    expect(["on", "off", "absent"]).toContain(payload.state);
    expect(arrange((await readLog(log)).split("\n"))).toEqual([`ifconfig ${ifconfig} awdl0`]);
  });

  test.skipIf(process.platform !== "darwin")("two consecutive status reads are shaped the same and change nothing", async () => {
    const first = reportOf((await exec(["awdl", "--json"], envFor(box.home, ifconfig))).stdout);
    const second = reportOf((await exec(["awdl", "--json"], envFor(box.home, ifconfig))).stdout);
    expect(second.changed).toBe(false);
    expect(second.outcome).toBeNull();
    expect(second.platform).toBe(first.platform);
    expect(second.interface).toBe(first.interface);
    expect(arrange((await readLog(log)).split("\n"))).toEqual([
      `ifconfig ${ifconfig} awdl0`,
      `ifconfig ${ifconfig} awdl0`,
      `ifconfig ${ifconfig} awdl0`,
    ]);
  });

  test.skipIf(process.platform !== "darwin")("--print-privilege returns the compiled two-rule sudoers payload without installing anything", async () => {
    const run = await exec(["awdl", "--print-privilege", "--json"], envFor(box.home, ifconfig));
    expect(run.code).toBe(0);
    expect(run.stderr).toBe("");
    const payload = JSON.parse(run.stdout) as AwdlPrivilege;
    expect(Object.keys(payload).sort()).toEqual(["allowed", "path", "rule", "user"]);
    expect(payload.user).toBe("e2etester");
    expect(payload.path).toBe("/etc/sudoers.d/dustless-awdl");
    expect(payload.allowed).toEqual([`${ifconfig} awdl0 down`, `${ifconfig} awdl0 up`]);
    expect(payload.rule).toBe(
      `e2etester ALL=(root) NOPASSWD: ${ifconfig} awdl0 down, ${ifconfig} awdl0 up\n`,
    );
    const human = await exec(["awdl", "--print-privilege"], envFor(box.home, ifconfig));
    expect(human.code).toBe(0);
    expect(human.stdout).toBe(payload.rule);
    expect(arrange((await readLog(log)).split("\n"))).toEqual([
      `ifconfig ${ifconfig} awdl0`,
      `ifconfig ${ifconfig} awdl0`,
      `ifconfig ${ifconfig} awdl0`,
    ]);
  });
});

describe("awdl --off through the fake ifconfig — macOS only", () => {
  let box: Sandbox;
  let log: string;
  let ifconfig: string;
  beforeAll(async () => {
    box = await sandbox("awdl-off");
    const installed = await installFakeIfconfig(box.home, "pass");
    log = installed.log;
    ifconfig = installed.ifconfig;
  });
  afterAll(async () => {
    await box.dispose();
  });

  test.skipIf(process.platform !== "darwin")("the fake sudo receives exactly the documented command and the fake ifconfig runs awdl0 down", async () => {
    const run = await exec(["awdl", "--off", "--json"], envFor(box.home, ifconfig));
    expect(run.code).toBe(0);
    assertReportShape(run);
    const payload = reportOf(run.stdout);
    expect(payload.platform).toBe("mac");
    expect(payload.interface).toBe("awdl0");
    expect(payload.changed).toBe(true);
    expect(payload.state).toBe("off");
    expect(payload.outcome).toEqual({
      status: "ran",
      detail: "awdl0 down — Wi-Fi stays stable",
    });
    expect(arrange((await readLog(log)).split("\n"))).toEqual([
      `sudo -n ${ifconfig} awdl0 down`,
      `ifconfig ${ifconfig} awdl0 down`,
      `ifconfig ${ifconfig} awdl0`,
    ]);
  });

  test.skipIf(process.platform !== "darwin")("human mode prints the ran marker and detail", async () => {
    const run = await exec(["awdl", "--off"], envFor(box.home, ifconfig));
    expect(run.code).toBe(0);
    expect(run.stdout).toContain("dustless awdl");
    expect(run.stdout).toContain("awdl0 down — Wi-Fi stays stable");
  });

  test.skipIf(process.platform !== "darwin")("both the toggle and the state read ran the sandboxed fake, never /sbin/ifconfig", async () => {
    const lines = arrange((await readLog(log)).split("\n"));
    expect(lines).toEqual([
      `sudo -n ${ifconfig} awdl0 down`,
      `ifconfig ${ifconfig} awdl0 down`,
      `ifconfig ${ifconfig} awdl0`,
      `sudo -n ${ifconfig} awdl0 down`,
      `ifconfig ${ifconfig} awdl0 down`,
      `ifconfig ${ifconfig} awdl0`,
    ]);
    for (const line of lines) {
      expect(line.startsWith("ifconfig /sbin/ifconfig") || line.startsWith("sudo -n /sbin/ifconfig")).toBe(false);
    }
    expect(lines.filter((line) => line.includes(`ifconfig ${ifconfig} awdl0 down`)).length).toBe(2);
    expect(lines.filter((line) => line === `ifconfig ${ifconfig} awdl0`).length).toBe(2);
  });
});

describe("awdl --on through the fake ifconfig — macOS only", () => {
  let box: Sandbox;
  let log: string;
  let ifconfig: string;
  beforeAll(async () => {
    box = await sandbox("awdl-on");
    const installed = await installFakeIfconfig(box.home, "pass");
    log = installed.log;
    ifconfig = installed.ifconfig;
  });
  afterAll(async () => {
    await box.dispose();
  });

  test.skipIf(process.platform !== "darwin")("the fake ifconfig executes only awdl0 up and the outcome is ran", async () => {
    const run = await exec(["awdl", "--on", "--json"], envFor(box.home, ifconfig));
    expect(run.code).toBe(0);
    const payload = reportOf(run.stdout);
    expect(payload.changed).toBe(true);
    expect(payload.outcome).toEqual({
      status: "ran",
      detail: "awdl0 up — AirDrop/Handoff available",
    });
    expect(arrange((await readLog(log)).split("\n"))).toEqual([
      `sudo -n ${ifconfig} awdl0 up`,
      `ifconfig ${ifconfig} awdl0 up`,
      `ifconfig ${ifconfig} awdl0`,
    ]);
  });
});

describe("awdl --off refused when sudo demands a password — macOS only", () => {
  let box: Sandbox;
  let log: string;
  let ifconfig: string;
  beforeAll(async () => {
    box = await sandbox("awdl-refused");
    const installed = await installFakeIfconfig(box.home, "consent");
    log = installed.log;
    ifconfig = installed.ifconfig;
  });
  afterAll(async () => {
    await box.dispose();
  });

  test.skipIf(process.platform !== "darwin")("the outcome is refused, nothing beyond the fake sudo probe and the faked state read ran, exit code 0", async () => {
    const run = await exec(["awdl", "--off", "--json"], envFor(box.home, ifconfig));
    expect(run.code).toBe(0);
    const payload = reportOf(run.stdout);
    expect(payload.changed).toBe(false);
    expect(payload.outcome?.status).toBe("refused");
    expect(payload.outcome?.detail).toContain("cần quyền root");
    expect(arrange((await readLog(log)).split("\n"))).toEqual([
      `sudo -n ${ifconfig} awdl0 down`,
      `ifconfig ${ifconfig} awdl0`,
    ]);
  });
});

describe("awdl --off failed when ifconfig itself fails — macOS only", () => {
  let box: Sandbox;
  let log: string;
  let ifconfig: string;
  beforeAll(async () => {
    box = await sandbox("awdl-failed");
    const installed = await installFakeIfconfig(box.home, "fail");
    log = installed.log;
    ifconfig = installed.ifconfig;
  });
  afterAll(async () => {
    await box.dispose();
  });

  test.skipIf(process.platform !== "darwin")("the outcome is failed with the ifconfig stderr as detail and exit code 1", async () => {
    const run = await exec(["awdl", "--off", "--json"], envFor(box.home, ifconfig));
    expect(run.code).toBe(1);
    const payload = reportOf(run.stdout);
    expect(payload.changed).toBe(false);
    expect(payload.outcome?.status).toBe("failed");
    expect(payload.outcome?.detail).toBe("ifconfig: awdl0: operation not permitted");
    expect(arrange((await readLog(log)).split("\n"))).toEqual([
      `sudo -n ${ifconfig} awdl0 down`,
      `ifconfig ${ifconfig} awdl0 down`,
      `ifconfig ${ifconfig} awdl0`,
    ]);
  });
});

describe("awdl clean refusal on non-macOS — Linux/Windows only", () => {
  let box: Sandbox;
  beforeAll(async () => {
    box = await sandbox("awdl-linux-refusal");
  });
  afterAll(async () => {
    await box.dispose();
  });

  test.skipIf(process.platform === "darwin")("awdl status is a clean read with a null outcome", async () => {
    const run = await box.run(["awdl", "--json"]);
    expect(run.code).toBe(0);
    expect(run.stderr).toBe("");
    const payload = reportOf(run.stdout);
    expect(Object.keys(payload).sort()).toEqual(["changed", "interface", "outcome", "platform", "state"]);
    expect(payload.platform).toBe(currentPlatform());
    expect(payload.interface).toBeNull();
    expect(payload.state).toBe("absent");
    expect(payload.changed).toBe(false);
    expect(payload.outcome).toBeNull();
  });

  test.skipIf(process.platform === "darwin")("awdl --off returns not-applicable with exit code 0", async () => {
    const run = await box.run(["awdl", "--off", "--json"]);
    expect(run.code).toBe(0);
    expect(run.stderr).toBe("");
    const payload = reportOf(run.stdout);
    expect(payload.platform).toBe(currentPlatform());
    expect(payload.interface).toBeNull();
    expect(payload.state).toBe("absent");
    expect(payload.changed).toBe(false);
    expect(payload.outcome).toEqual({ status: "not-applicable", detail: "AWDL only exists on macOS" });
  });

  test.skipIf(process.platform === "darwin")("awdl --on returns not-applicable with exit code 0", async () => {
    const run = await box.run(["awdl", "--on", "--json"]);
    expect(run.code).toBe(0);
    expect(run.stderr).toBe("");
    const payload = reportOf(run.stdout);
    expect(payload.platform).toBe(currentPlatform());
    expect(payload.interface).toBeNull();
    expect(payload.state).toBe("absent");
    expect(payload.changed).toBe(false);
    expect(payload.outcome).toEqual({ status: "not-applicable", detail: "AWDL only exists on macOS" });
  });

  test.skipIf(process.platform === "darwin")("awdl --print-privilege still returns the payload: the guard gates only the toggle", async () => {
    const run = await exec(["awdl", "--print-privilege", "--json"], {
      PATH: "/usr/bin:/bin",
      HOME: box.home,
      TMPDIR: box.home,
      USER: "e2etester",
      NO_COLOR: "1",
    });
    expect(run.code).toBe(0);
    expect(run.stderr).toBe("");
    const payload = JSON.parse(run.stdout) as AwdlPrivilege;
    expect(Object.keys(payload).sort()).toEqual(["allowed", "path", "rule", "user"]);
    expect(payload.user).toBe("e2etester");
    expect(payload.path).toBe("/etc/sudoers.d/dustless-awdl");
  });

  test.skipIf(process.platform === "darwin")("awdl --print-privilege refuses cleanly when USER is unusable", async () => {
    const run = await box.run(["awdl", "--print-privilege", "--json"]);
    expect(run.code).toBe(1);
    expect(JSON.parse(run.stdout)).toEqual({ error: 'không dùng được "" cho quy tắc sudoers' });
  });
});