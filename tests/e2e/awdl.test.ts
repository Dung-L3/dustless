import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { exec, sandbox, type Sandbox } from "./harness.ts";

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
echo "ifconfig $*" >> "${log}"
exit 0
`;

const IFCONFIG_FAIL = (log: string): string => `#!/bin/sh
echo "ifconfig $*" >> "${log}"
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

async function installFakeSudo(
  home: string,
  variant: "pass" | "fail" | "consent",
): Promise<string> {
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
  return log;
}

function envFor(home: string): Record<string, string> {
  return {
    PATH: `${join(home, ".bin")}:/usr/bin:/bin:/usr/sbin:/sbin`,
    HOME: home,
    USER: "e2etester",
    NO_COLOR: "1",
    TMPDIR: home,
  };
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

describe("awdl status and privilege payloads (read-only)", () => {
  let box: Sandbox;
  let log: string;
  beforeAll(async () => {
    box = await sandbox("awdl-status");
    log = await installFakeSudo(box.home, "pass");
  });
  afterAll(async () => {
    await box.dispose();
  });

  test("radio status reports the documented payload shape with no privilege command", async () => {
    const run = await exec(["awdl", "--json"], envFor(box.home));
    expect(run.code).toBe(0);
    expect(run.stderr).toBe("");
    assertReportShape(run);
    const payload = reportOf(run.stdout);
    expect(payload.platform).toBe("mac");
    expect(payload.interface).toBe("awdl0");
    expect(payload.changed).toBe(false);
    expect(payload.outcome).toBeNull();
    expect(["on", "off", "absent"]).toContain(payload.state);
    await expect(readLog(log)).resolves.toBe("");
  });

  test("two consecutive status reads are shaped the same and change nothing", async () => {
    const first = reportOf((await exec(["awdl", "--json"], envFor(box.home))).stdout);
    const second = reportOf((await exec(["awdl", "--json"], envFor(box.home))).stdout);
    expect(second.changed).toBe(false);
    expect(second.outcome).toBeNull();
    expect(second.platform).toBe(first.platform);
    expect(second.interface).toBe(first.interface);
    await expect(readLog(log)).resolves.toBe("");
  });

  test("--print-privilege returns the compiled two-rule sudoers payload without installing anything", async () => {
    const run = await exec(["awdl", "--print-privilege", "--json"], envFor(box.home));
    expect(run.code).toBe(0);
    expect(run.stderr).toBe("");
    const payload = JSON.parse(run.stdout) as AwdlPrivilege;
    expect(Object.keys(payload).sort()).toEqual(["allowed", "path", "rule", "user"]);
    expect(payload.user).toBe("e2etester");
    expect(payload.path).toBe("/etc/sudoers.d/dustless-awdl");
    expect(payload.allowed).toEqual(["/sbin/ifconfig awdl0 down", "/sbin/ifconfig awdl0 up"]);
    expect(payload.rule).toBe(
      "e2etester ALL=(root) NOPASSWD: /sbin/ifconfig awdl0 down, /sbin/ifconfig awdl0 up\n",
    );
    const human = await exec(["awdl", "--print-privilege"], envFor(box.home));
    expect(human.code).toBe(0);
    expect(human.stdout).toBe(payload.rule);
    await expect(readLog(log)).resolves.toBe("");
  });
});

describe("awdl --off through the fake ifconfig", () => {
  let box: Sandbox;
  let log: string;
  beforeAll(async () => {
    box = await sandbox("awdl-off");
    log = await installFakeSudo(box.home, "pass");
  });
  afterAll(async () => {
    await box.dispose();
  });

  test("the fake sudo receives exactly the documented command and the fake ifconfig runs awdl0 down", async () => {
    const run = await exec(["awdl", "--off", "--json"], envFor(box.home));
    expect(run.code).toBe(0);
    assertReportShape(run);
    const payload = reportOf(run.stdout);
    expect(payload.platform).toBe("mac");
    expect(payload.interface).toBe("awdl0");
    expect(payload.changed).toBe(true);
    expect(payload.outcome).toEqual({
      status: "ran",
      detail: "awdl0 down — Wi-Fi stays stable",
    });
    const calls = (await readLog(log)).trim().split("\n");
    expect(calls).toEqual(["sudo -n /sbin/ifconfig awdl0 down", "ifconfig awdl0 down"]);
  });

  test("human mode prints the ran marker and detail", async () => {
    const run = await exec(["awdl", "--off"], envFor(box.home));
    expect(run.code).toBe(0);
    expect(run.stdout).toContain("dustless awdl");
    expect(run.stdout).toContain("awdl0 down — Wi-Fi stays stable");
  });
});

describe("awdl --on through the fake ifconfig", () => {
  let box: Sandbox;
  let log: string;
  beforeAll(async () => {
    box = await sandbox("awdl-on");
    log = await installFakeSudo(box.home, "pass");
  });
  afterAll(async () => {
    await box.dispose();
  });

  test("the fake ifconfig executes only awdl0 up and the outcome is ran", async () => {
    const run = await exec(["awdl", "--on", "--json"], envFor(box.home));
    expect(run.code).toBe(0);
    const payload = reportOf(run.stdout);
    expect(payload.changed).toBe(true);
    expect(payload.outcome).toEqual({
      status: "ran",
      detail: "awdl0 up — AirDrop/Handoff available",
    });
    const calls = (await readLog(log)).trim().split("\n");
    expect(calls).toEqual(["sudo -n /sbin/ifconfig awdl0 up", "ifconfig awdl0 up"]);
  });
});

describe("awdl --off refused when sudo demands a password", () => {
  let box: Sandbox;
  let log: string;
  beforeAll(async () => {
    box = await sandbox("awdl-refused");
    log = await installFakeSudo(box.home, "consent");
  });
  afterAll(async () => {
    await box.dispose();
  });

  test("the outcome is refused, nothing beyond the sudo probe ran, exit code 0", async () => {
    const run = await exec(["awdl", "--off", "--json"], envFor(box.home));
    expect(run.code).toBe(0);
    const payload = reportOf(run.stdout);
    expect(payload.changed).toBe(false);
    expect(payload.outcome?.status).toBe("refused");
    expect(payload.outcome?.detail).toContain("cần quyền root");
    const calls = (await readLog(log)).trim().split("\n");
    expect(calls).toEqual(["sudo -n /sbin/ifconfig awdl0 down"]);
  });
});

describe("awdl --off failed when ifconfig itself fails", () => {
  let box: Sandbox;
  let log: string;
  beforeAll(async () => {
    box = await sandbox("awdl-failed");
    log = await installFakeSudo(box.home, "fail");
  });
  afterAll(async () => {
    await box.dispose();
  });

  test("the outcome is failed with the ifconfig stderr as detail and exit code 1", async () => {
    const run = await exec(["awdl", "--off", "--json"], envFor(box.home));
    expect(run.code).toBe(1);
    const payload = reportOf(run.stdout);
    expect(payload.changed).toBe(false);
    expect(payload.outcome?.status).toBe("failed");
    expect(payload.outcome?.detail).toBe("ifconfig: awdl0: operation not permitted");
    const calls = (await readLog(log)).trim().split("\n");
    expect(calls).toEqual(["sudo -n /sbin/ifconfig awdl0 down", "ifconfig awdl0 down"]);
  });
});
