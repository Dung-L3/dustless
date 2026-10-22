import { describe, expect, test } from "bun:test";
import { awdlPrivilege, AWDL_PRIVILEGE_PATH, IFCONFIG, IFCONFIG_ALLOWLIST } from "../src/core/net/awdl.ts";
import { netPrivilegeSteps } from "../src/core/net/commands.ts";
import {
  NET_COMMAND_ALLOWLIST,
  NET_PRIVILEGE_PATH,
  netPrivilege,
  sudoersArg,
  sudoersPath,
  sudoersRule,
  validSudoersUser,
} from "../src/core/net/privilege.ts";
import type { NetInfo } from "../src/core/net/inspect.ts";

const INFO: NetInfo = { iface: "en0", gateway: "192.168.1.1", dns: [], service: "Wi-Fi", soloRoute: true };

const HOSTILE_VALUES = [
  "Wi\tFi",
  "Wi-Fi\nALL=(root) NOPASSWD: /bin/sh",
  "Wi-Fi\rALL=(root) NOPASSWD: /bin/sh",
  "Wi-Fi\0",
  "Wi-Fi\x01",
  "Wi-Fi\x1b",
  "Wi-Fi\x7f",
  "Wi-Fi;rm",
  "Wi-Fi|cat",
  "Wi-Fi&",
  "Wi-Fi$HOME",
  "Wi-Fi`id`",
  "Wi-Fi>out",
  "Wi-Fi<input",
  "Wi-Fi(1)",
  "Wi-Fi{1}",
  "Wi-Fi!",
  "Wi-Fi'x'",
  'Wi"Fi',
  "Wi-Fi\\x",
  "Wi-Fi#x",
  "Wi-Fi,rm",
  "Wi*Fi",
  "Wi?Fi",
  "Wi-Fi[0-9]",
];

describe("the sudoers validator refuses every character that can change a rule", () => {
  test("a tab in a network service name is refused instead of reaching the rule", () => {
    expect(() => netPrivilege("mac", netPrivilegeSteps({ ...INFO, service: "Wi\tFi" }))).toThrow();
  });

  test("every control character is refused in a value that reaches a rule", () => {
    for (const value of HOSTILE_VALUES) {
      expect(() => sudoersArg(value)).toThrow();
    }
  });

  test("a shell metacharacter or a command separator is refused", () => {
    for (const value of ["a;b", "a|b", "a&b", "a$b", "a`b", "a>b", "a<b", "a(b)", "a{b}", "a!b", "a'b", 'a"b', "a\\b", "a#b", "a,b"]) {
      expect(() => sudoersArg(value)).toThrow();
    }
  });

  test("a value that carries a forbidden character inside a quoted region is refused", () => {
    expect(() => sudoersRule("mac", ['/sbin/ifconfig "a;b"'])).toThrow();
    expect(() => sudoersRule("mac", ['/sbin/ifconfig "a b"'])).not.toThrow();
  });

  test("a rule that is not one well-formed line is refused", () => {
    expect(() => sudoersRule("mac", [])).toThrow();
    expect(() => sudoersRule("mac", ["/sbin/ifconfig awdl0 down\nroot ALL=(root) NOPASSWD: /bin/sh"])).toThrow();
    expect(() => sudoersRule("mac", ["/sbin/ifconfig awdl0 down, root ALL=(root) NOPASSWD: /bin/sh"])).toThrow();
  });

  test("an account name that could inject a second rule is refused", () => {
    for (const user of ["", "ALL", "all", "a b", "mac\nroot ALL=(root) NOPASSWD: /bin/sh", "mac\rALL=(root) ALL", "-x", ".", "..", "a,b"]) {
      expect(validSudoersUser(user)).toBe(false);
      expect(() => sudoersRule(user, ["/sbin/ifconfig awdl0 down"])).toThrow();
    }
  });
});

describe("every executable that reaches a rule comes from an allowlist", () => {
  test("the AWDL rule names the one allowlisted system executable", () => {
    expect(IFCONFIG_ALLOWLIST).toEqual(["/sbin/ifconfig"]);
    expect(IFCONFIG).toBe("/sbin/ifconfig");
    expect(awdlPrivilege("mac").allowed).toEqual([
      "/sbin/ifconfig awdl0 down",
      "/sbin/ifconfig awdl0 up",
    ]);
    expect(awdlPrivilege("mac").path).toBe(AWDL_PRIVILEGE_PATH);
  });

  test("the net rule names only the three allowlisted system executables", () => {
    expect(NET_COMMAND_ALLOWLIST).toEqual([
      "/usr/sbin/networksetup",
      "/usr/sbin/ipconfig",
      "/usr/sbin/arp",
    ]);
    const privilege = netPrivilege("mac", netPrivilegeSteps(INFO));
    for (const command of privilege.allowed) {
      expect(NET_COMMAND_ALLOWLIST.some((allowed) => command.startsWith(`${allowed} `))).toBe(true);
    }
    expect(privilege.path).toBe(NET_PRIVILEGE_PATH);
  });

  test("a step whose executable is not on the allowlist is refused", () => {
    for (const cmd of ["/bin/sh", "/usr/bin/networksetup", "networksetup", "/usr/sbin/arp;id", "/usr/sbin/arp "]) {
      expect(() => netPrivilege("mac", [{ cmd, args: [] }])).toThrow();
    }
  });

  test("an absolute path outside the allowlist is refused", () => {
    expect(() => sudoersPath("/bin/sh", IFCONFIG_ALLOWLIST)).toThrow();
    expect(() => sudoersPath("/usr/sbin/ifconfig", IFCONFIG_ALLOWLIST)).toThrow();
    expect(() => sudoersPath("sbin/ifconfig", IFCONFIG_ALLOWLIST)).toThrow();
    expect(() => sudoersPath("/sbin/ifconfig", IFCONFIG_ALLOWLIST)).not.toThrow();
  });
});

describe("the printed rule is one line of a known shape", () => {
  test("the AWDL rule is the exact expected line", () => {
    expect(awdlPrivilege("mac").rule).toBe(
      "mac ALL=(root) NOPASSWD: /sbin/ifconfig awdl0 down, /sbin/ifconfig awdl0 up\n",
    );
  });

  test("the net rule is the exact expected line", () => {
    expect(netPrivilege("mac", netPrivilegeSteps(INFO)).rule).toBe(
      "mac ALL=(root) NOPASSWD: /usr/sbin/networksetup -setdnsservers Wi-Fi Empty,"
        + " /usr/sbin/ipconfig set en0 DHCP,"
        + " /usr/sbin/arp -d -a,"
        + " /usr/sbin/networksetup -setMTU Wi-Fi 1500\n",
    );
  });

  test("both rules hold one line and nothing a rule cannot carry", () => {
    for (const rule of [awdlPrivilege("mac").rule, netPrivilege("mac", netPrivilegeSteps(INFO)).rule]) {
      expect(rule.split("\n")).toHaveLength(2);
      expect(rule.endsWith("\n")).toBe(true);
      expect(rule.slice(0, -1)).toMatch(
        /^[A-Za-z0-9._-]{1,32} ALL=\(root\) NOPASSWD: [A-Za-z0-9._:@/+=%~-]+( "[A-Za-z0-9._:@/+=%~ -]+"| [A-Za-z0-9._:@/+=%~-]+)*(, [A-Za-z0-9._:@/+=%~-]+( "[A-Za-z0-9._:@/+=%~ -]+"| [A-Za-z0-9._:@/+=%~-]+)*)*$/,
      );
    }
  });
});
