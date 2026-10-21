import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { BINARY, exec, sandbox, type Sandbox } from "./harness.ts";
import { currentPlatform } from "./harness.ts";

type AwdlReport = {
  platform: string;
  interface: string | null;
  state: "on" | "off" | "absent";
  changed: boolean;
  outcome: { status: string; detail: string } | null;
};

type AwdlPrivilege = { user: string; path: string; allowed: string[]; rule: string };

const HOSTILE_IFCONFIG = "/tmp/evil\nmac ALL=(root) NOPASSWD: /bin/sh\n#";

const FIXED_RULE =
  "e2etester ALL=(root) NOPASSWD: /sbin/ifconfig awdl0 down, /sbin/ifconfig awdl0 up\n";

const RUNNING_AS_ROOT = typeof process.getuid === "function" && process.getuid() === 0;

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
): Promise<{ sudoLog: string; ifconfigLog: string; ifconfig: string }> {
  const bin = join(home, ".bin");
  await mkdir(bin, { recursive: true });
  const sudoLog = join(bin, "sudo.log");
  const ifconfigLog = join(bin, "ifconfig.log");
  const ifconfig = join(bin, "ifconfig.sh");
  const sudo = join(bin, "sudo");
  const body =
    variant === "fail" ? IFCONFIG_FAIL(ifconfigLog) : IFCONFIG_FAKE(ifconfigLog);
  await writeFile(ifconfig, body);
  await chmod(ifconfig, 0o755);
  await writeFile(sudo, variant === "consent" ? SUDO_CONSENT(sudoLog) : SUDO_PASS(sudoLog, ifconfig));
  await chmod(sudo, 0o755);
  return { sudoLog, ifconfigLog, ifconfig };
}

function envFor(home: string): Record<string, string> {
  return {
    PATH: `${join(home, ".bin")}:/usr/bin:/bin:/usr/sbin:/sbin`,
    HOME: home,
    USER: "e2etester",
    NO_COLOR: "1",
    TMPDIR: home,
    DUSTLESS_IFCONFIG: HOSTILE_IFCONFIG,
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

describe("the shipped engine binary", () => {
  test("carries no environment override that could pick the executable", async () => {
    const binary = await readFile(BINARY);
    expect(binary.includes(Buffer.from("DUSTLESS_IFCONFIG"))).toBe(false);
  });
});

describe("awdl status and privilege payloads (read-only) — macOS only", () => {
  let box: Sandbox;
  let sudoLog: string;
  let ifconfigLog: string;
  beforeAll(async () => {
    box = await sandbox("awdl-status");
    const installed = await installFakeIfconfig(box.home, "pass");
    sudoLog = installed.sudoLog;
    ifconfigLog = installed.ifconfigLog;
  });
  afterAll(async () => {
    await box.dispose();
  });

  test.skipIf(process.platform !== "darwin")("radio status reports the documented payload shape with no privilege command", async () => {
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
    expect(arrange((await readLog(sudoLog)).split("\n"))).toEqual([]);
    expect(arrange((await readLog(ifconfigLog)).split("\n"))).toEqual([]);
  });

  test.skipIf(process.platform !== "darwin")("two consecutive status reads are shaped the same and change nothing", async () => {
    const first = reportOf((await exec(["awdl", "--json"], envFor(box.home))).stdout);
    const second = reportOf((await exec(["awdl", "--json"], envFor(box.home))).stdout);
    expect(second.changed).toBe(false);
    expect(second.outcome).toBeNull();
    expect(second.platform).toBe(first.platform);
    expect(second.interface).toBe(first.interface);
    expect(arrange((await readLog(sudoLog)).split("\n"))).toEqual([]);
    expect(arrange((await readLog(ifconfigLog)).split("\n"))).toEqual([]);
  });

  test.skipIf(process.platform !== "darwin")("--print-privilege returns the fixed two-rule sudoers payload without installing anything", async () => {
    const run = await exec(["awdl", "--print-privilege", "--json"], envFor(box.home));
    expect(run.code).toBe(0);
    expect(run.stderr).toBe("");
    const payload = JSON.parse(run.stdout) as AwdlPrivilege;
    expect(Object.keys(payload).sort()).toEqual(["allowed", "path", "rule", "user"]);
    expect(payload.user).toBe("e2etester");
    expect(payload.path).toBe("/etc/sudoers.d/dustless-awdl");
    expect(payload.allowed).toEqual(["/sbin/ifconfig awdl0 down", "/sbin/ifconfig awdl0 up"]);
    expect(payload.rule).toBe(FIXED_RULE);
    expect(payload.rule).not.toContain("evil");
    expect(payload.rule).not.toContain("/bin/sh");
    expect(payload.rule.split("\n")).toHaveLength(2);
    const human = await exec(["awdl", "--print-privilege"], envFor(box.home));
    expect(human.code).toBe(0);
    expect(human.stdout).toBe(payload.rule);
    expect(arrange((await readLog(sudoLog)).split("\n"))).toEqual([]);
    expect(arrange((await readLog(ifconfigLog)).split("\n"))).toEqual([]);
  });
});

describe("awdl --off through the fake sudo — macOS only", () => {
  let box: Sandbox;
  let sudoLog: string;
  let ifconfigLog: string;
  let ifconfig: string;
  beforeAll(async () => {
    box = await sandbox("awdl-off");
    const installed = await installFakeIfconfig(box.home, "pass");
    sudoLog = installed.sudoLog;
    ifconfigLog = installed.ifconfigLog;
    ifconfig = installed.ifconfig;
  });
  afterAll(async () => {
    await box.dispose();
  });

  test.skipIf(process.platform !== "darwin" || RUNNING_AS_ROOT)("the fake sudo receives exactly the documented command and the fake ifconfig runs awdl0 down", async () => {
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
    expect(["on", "off", "absent"]).toContain(payload.state);
    expect(arrange((await readLog(sudoLog)).split("\n"))).toEqual([
      "sudo -n /sbin/ifconfig awdl0 down",
    ]);
    expect(arrange((await readLog(ifconfigLog)).split("\n"))).toEqual([
      `ifconfig ${ifconfig} awdl0 down`,
    ]);
  });

  test.skipIf(process.platform !== "darwin" || RUNNING_AS_ROOT)("human mode prints the ran marker and detail", async () => {
    const run = await exec(["awdl", "--off"], envFor(box.home));
    expect(run.code).toBe(0);
    expect(run.stdout).toContain("dustless awdl");
    expect(run.stdout).toContain("awdl0 down — Wi-Fi stays stable");
  });

  test.skipIf(process.platform !== "darwin" || RUNNING_AS_ROOT)("every escalation named the fixed system path and the sandboxed fake ran instead", async () => {
    const sudoLines = arrange((await readLog(sudoLog)).split("\n"));
    const fakeLines = arrange((await readLog(ifconfigLog)).split("\n"));
    expect(sudoLines).toEqual([
      "sudo -n /sbin/ifconfig awdl0 down",
      "sudo -n /sbin/ifconfig awdl0 down",
    ]);
    expect(fakeLines).toEqual([
      `ifconfig ${ifconfig} awdl0 down`,
      `ifconfig ${ifconfig} awdl0 down`,
    ]);
    for (const line of fakeLines) {
      expect(line.startsWith("ifconfig /sbin/ifconfig")).toBe(false);
    }
  });
});

describe("awdl --on through the fake sudo — macOS only", () => {
  let box: Sandbox;
  let sudoLog: string;
  let ifconfigLog: string;
  let ifconfig: string;
  beforeAll(async () => {
    box = await sandbox("awdl-on");
    const installed = await installFakeIfconfig(box.home, "pass");
    sudoLog = installed.sudoLog;
    ifconfigLog = installed.ifconfigLog;
    ifconfig = installed.ifconfig;
  });
  afterAll(async () => {
    await box.dispose();
  });

  test.skipIf(process.platform !== "darwin" || RUNNING_AS_ROOT)("the fake ifconfig executes only awdl0 up and the outcome is ran", async () => {
    const run = await exec(["awdl", "--on", "--json"], envFor(box.home));
    expect(run.code).toBe(0);
    const payload = reportOf(run.stdout);
    expect(payload.changed).toBe(true);
    expect(payload.outcome).toEqual({
      status: "ran",
      detail: "awdl0 up — AirDrop/Handoff available",
    });
    expect(["on", "off", "absent"]).toContain(payload.state);
    expect(arrange((await readLog(sudoLog)).split("\n"))).toEqual([
      "sudo -n /sbin/ifconfig awdl0 up",
    ]);
    expect(arrange((await readLog(ifconfigLog)).split("\n"))).toEqual([
      `ifconfig ${ifconfig} awdl0 up`,
    ]);
  });
});

describe("awdl --off refused when sudo demands a password — macOS only", () => {
  let box: Sandbox;
  let sudoLog: string;
  let ifconfigLog: string;
  beforeAll(async () => {
    box = await sandbox("awdl-refused");
    const installed = await installFakeIfconfig(box.home, "consent");
    sudoLog = installed.sudoLog;
    ifconfigLog = installed.ifconfigLog;
  });
  afterAll(async () => {
    await box.dispose();
  });

  test.skipIf(process.platform !== "darwin" || RUNNING_AS_ROOT)("the outcome is refused, nothing beyond the fake sudo probe ran, exit code 0", async () => {
    const run = await exec(["awdl", "--off", "--json"], envFor(box.home));
    expect(run.code).toBe(0);
    const payload = reportOf(run.stdout);
    expect(payload.changed).toBe(false);
    expect(payload.outcome?.status).toBe("refused");
    expect(payload.outcome?.detail).toContain("cần quyền root");
    expect(["on", "off", "absent"]).toContain(payload.state);
    expect(arrange((await readLog(sudoLog)).split("\n"))).toEqual([
      "sudo -n /sbin/ifconfig awdl0 down",
    ]);
    expect(arrange((await readLog(ifconfigLog)).split("\n"))).toEqual([]);
  });
});

describe("awdl --off failed when the command fails — macOS only", () => {
  let box: Sandbox;
  let sudoLog: string;
  let ifconfigLog: string;
  let ifconfig: string;
  beforeAll(async () => {
    box = await sandbox("awdl-failed");
    const installed = await installFakeIfconfig(box.home, "fail");
    sudoLog = installed.sudoLog;
    ifconfigLog = installed.ifconfigLog;
    ifconfig = installed.ifconfig;
  });
  afterAll(async () => {
    await box.dispose();
  });

  test.skipIf(process.platform !== "darwin" || RUNNING_AS_ROOT)("the outcome is failed with the command stderr as detail and exit code 1", async () => {
    const run = await exec(["awdl", "--off", "--json"], envFor(box.home));
    expect(run.code).toBe(1);
    const payload = reportOf(run.stdout);
    expect(payload.changed).toBe(false);
    expect(payload.outcome?.status).toBe("failed");
    expect(payload.outcome?.detail).toBe("ifconfig: awdl0: operation not permitted");
    expect(["on", "off", "absent"]).toContain(payload.state);
    expect(arrange((await readLog(sudoLog)).split("\n"))).toEqual([
      "sudo -n /sbin/ifconfig awdl0 down",
    ]);
    expect(arrange((await readLog(ifconfigLog)).split("\n"))).toEqual([
      `ifconfig ${ifconfig} awdl0 down`,
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
      DUSTLESS_IFCONFIG: HOSTILE_IFCONFIG,
    });
    expect(run.code).toBe(0);
    expect(run.stderr).toBe("");
    const payload = JSON.parse(run.stdout) as AwdlPrivilege;
    expect(Object.keys(payload).sort()).toEqual(["allowed", "path", "rule", "user"]);
    expect(payload.user).toBe("e2etester");
    expect(payload.path).toBe("/etc/sudoers.d/dustless-awdl");
    expect(payload.allowed).toEqual(["/sbin/ifconfig awdl0 down", "/sbin/ifconfig awdl0 up"]);
    expect(payload.rule).toBe(FIXED_RULE);
  });

  test.skipIf(process.platform === "darwin")("awdl --print-privilege refuses cleanly when USER is unusable", async () => {
    const run = await box.run(["awdl", "--print-privilege", "--json"]);
    expect(run.code).toBe(1);
    expect(JSON.parse(run.stdout)).toEqual({ error: 'không dùng được "" cho quy tắc sudoers' });
  });
});
