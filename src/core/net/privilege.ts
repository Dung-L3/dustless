import { validSudoersUser } from "./awdl.ts";
import type { Step } from "./commands.ts";

// The one-time "remember this authorization" step for the Network panel.
//
// We are NOT saving the user's password, and nothing here ever sees it. What we
// install is a sudoers rule scoped to one account and four exact commands: the
// advanced network operations, on this machine's current interface and service,
// with no wildcards and no shell. macOS then lets the engine run those four
// commands with `sudo -n` without asking again — and refuses everything else,
// exactly like before. The user can remove the file at any time
// (`sudo rm /etc/sudoers.d/dustless-net`) and the panel offers to do it.
export const NET_PRIVILEGE_PATH = "/etc/sudoers.d/dustless-net";

export type NetPrivilege = {
  user: string;
  path: string;
  /** The commands the rule permits, each absolute and exact, as sudoers spells them. */
  allowed: string[];
  /** The full sudoers.d line, newline-terminated. */
  rule: string;
};

/**
 * The sudoers rule for the given advanced steps. Throws rather than emitting a
 * weaker rule: an unusable rule that half-matches would leave sudo failing at
 * the worst moment, and a missing interface means we cannot write an exact one.
 */
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

/** One step as a sudoers command spec: absolute path plus its exact arguments. */
function sudoersStep(step: Step): string {
  return [step.cmd, ...step.args].map(sudoersArg).join(" ");
}

/**
 * One argument as sudoers spells it. Sudoers splits its own arguments on
 * whitespace, so a service name with spaces ("USB 10/100/1000 LAN") has to be
 * double-quoted — and the engine passes the same value as a single argv
 * element, which is what makes the rule match.
 *
 * Four kinds of value are refused rather than escaped, because escaping does not
 * mean the same thing to sudoers as it does to a shell: `"` ends the argument
 * and starts a comment (`#`) or a second rule; and `* ? [ ] \` are sudoers
 * wildcards, so a rule containing one matches a whole family of commands
 * instead of the one exact command this file exists to allow.
 */
function sudoersArg(value: string): string {
  if (value === "" || /["\n\r#*?\[\]\\]/.test(value)) {
    throw new Error(`cannot put ${JSON.stringify(value)} in a sudoers rule`);
  }
  return value.includes(" ") ? `"${value}"` : value;
}