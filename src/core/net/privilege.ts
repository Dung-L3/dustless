import type { Step } from "./commands.ts";

export const NET_PRIVILEGE_PATH = "/etc/sudoers.d/dustless-net";

export type NetPrivilege = {
  user: string;
  path: string;
  allowed: string[];
  rule: string;
};

const SUDOERS_FORBIDDEN = /[\0\n\r;|&$<>(){}[\]*?!#\\'"\`,]/;

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
  if (value === "" || SUDOERS_FORBIDDEN.test(value)) {
    throw new Error(`cannot put ${JSON.stringify(value)} in a sudoers rule`);
  }
  return value.includes(" ") ? `"${value}"` : value;
}

export function sudoersPath(path: string, allowlist: readonly string[]): string {
  if (!path.startsWith("/")) {
    throw new Error(`cannot put ${JSON.stringify(path)} in a sudoers rule: it is not an absolute path`);
  }
  if (/\s/.test(path)) {
    throw new Error(`cannot put ${JSON.stringify(path)} in a sudoers rule: it contains whitespace`);
  }
  if (SUDOERS_FORBIDDEN.test(path)) {
    throw new Error(`cannot put ${JSON.stringify(path)} in a sudoers rule: it contains a forbidden character`);
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
  for (const command of allowed) {
    if (command === "" || SUDOERS_FORBIDDEN.test(command.replace(/"[^"]*"/g, ""))) {
      throw new Error(`cannot put ${JSON.stringify(command)} in a sudoers rule`);
    }
  }
  return `${user} ALL=(root) NOPASSWD: ${allowed.join(", ")}\n`;
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
  return [step.cmd, ...step.args].map(sudoersArg).join(" ");
}
