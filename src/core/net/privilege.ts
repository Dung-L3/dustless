import { MAC_COMMANDS, type Step } from "./commands.ts";

export const NET_PRIVILEGE_PATH = "/etc/sudoers.d/dustless-net";

export type NetPrivilege = {
  user: string;
  path: string;
  allowed: string[];
  rule: string;
};

export const NET_COMMAND_ALLOWLIST: readonly string[] = [
  MAC_COMMANDS.networksetup,
  MAC_COMMANDS.ipconfig,
  MAC_COMMANDS.arp,
];

const SUDOERS_CHARS = "A-Za-z0-9._:@/+=%~\\-";
const SUDOERS_BARE = new RegExp(`^[${SUDOERS_CHARS}]+$`);
const SUDOERS_QUOTED = new RegExp(`^[${SUDOERS_CHARS} ]+$`);
const SUDOERS_TOKEN = `(?:[${SUDOERS_CHARS}]+|"[${SUDOERS_CHARS} ]+")`;
const SUDOERS_RULE = new RegExp(
  `^[A-Za-z0-9._-]{1,32} ALL=\\(root\\) NOPASSWD: ${SUDOERS_TOKEN}(?: ${SUDOERS_TOKEN})*(?:, ${SUDOERS_TOKEN}(?: ${SUDOERS_TOKEN})*)*$`,
);

export function validSudoersUser(user: string): boolean {
  return (
    /^[A-Za-z0-9._-]{1,32}$/.test(user) &&
    !user.startsWith("-") &&
    user !== "." &&
    user !== ".." &&
    user.toLowerCase() !== "all"
  );
}

export function sudoersArg(value: string): string {
  if (value === "") {
    throw new Error(`cannot put ${JSON.stringify(value)} in a sudoers rule`);
  }
  if (value.includes(" ")) {
    if (!SUDOERS_QUOTED.test(value)) {
      throw new Error(`cannot put ${JSON.stringify(value)} in a sudoers rule`);
    }
    return `"${value}"`;
  }
  if (!SUDOERS_BARE.test(value)) {
    throw new Error(`cannot put ${JSON.stringify(value)} in a sudoers rule`);
  }
  return value;
}

export function sudoersPath(path: string, allowlist: readonly string[]): string {
  if (!path.startsWith("/")) {
    throw new Error(`cannot put ${JSON.stringify(path)} in a sudoers rule: it is not an absolute path`);
  }
  if (!SUDOERS_BARE.test(path)) {
    throw new Error(`cannot put ${JSON.stringify(path)} in a sudoers rule: it holds a character a sudoers rule cannot carry`);
  }
  if (!allowlist.includes(path)) {
    throw new Error(`${JSON.stringify(path)} is not an allowed sudoers command`);
  }
  return path;
}

export function sudoersRule(user: string, allowed: string[]): string {
  if (!validSudoersUser(user)) {
    throw new Error(`"${user}" is not usable as a sudoers account name`);
  }
  if (allowed.length === 0) {
    throw new Error("a sudoers rule needs at least one command");
  }
  for (const command of allowed) {
    if (command === "") {
      throw new Error(`cannot put ${JSON.stringify(command)} in a sudoers rule`);
    }
  }
  const rule = `${user} ALL=(root) NOPASSWD: ${allowed.join(", ")}\n`;
  if (!SUDOERS_RULE.test(rule.slice(0, -1))) {
    throw new Error(`cannot put ${JSON.stringify(allowed.join(", "))} in a sudoers rule`);
  }
  return rule;
}

export function netPrivilege(user: string, steps: Step[]): NetPrivilege {
  const allowed = steps.map(sudoersStep);
  return {
    user,
    path: NET_PRIVILEGE_PATH,
    allowed,
    rule: sudoersRule(user, allowed),
  };
}

function sudoersStep(step: Step): string {
  const cmd = sudoersPath(step.cmd, NET_COMMAND_ALLOWLIST);
  return [cmd, ...step.args.map(sudoersArg)].join(" ");
}
