import { validSudoersUser } from "./awdl.ts";
import type { Step } from "./commands.ts";

export const NET_PRIVILEGE_PATH = "/etc/sudoers.d/dustless-net";

export type NetPrivilege = {
  user: string;
  path: string;
  allowed: string[];
  rule: string;
};

export function netPrivilege(user: string, steps: Step[]): NetPrivilege {
  if (!validSudoersUser(user)) {
    throw new Error(`"${user}" is not usable as a sudoers account name`);
  }
  const allowed = steps.map(sudoersStep);
  return {
    user,
    path: NET_PRIVILEGE_PATH,
    allowed,
    rule: `${user} ALL=(root) NOPASSWD: ${allowed.join(", ")}\n`,
  };
}

function sudoersStep(step: Step): string {
  return [step.cmd, ...step.args].map(sudoersArg).join(" ");
}

function sudoersArg(value: string): string {
  if (value === "" || /["\n\r#*?\[\]\\]/.test(value)) {
    throw new Error(`cannot put ${JSON.stringify(value)} in a sudoers rule`);
  }
  return value.includes(" ") ? `"${value}"` : value;
}