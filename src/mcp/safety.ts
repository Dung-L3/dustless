import { parse, resolve, sep } from "node:path";
import { HOME, isRed, realGuard, RED_PATTERNS } from "../core/paths.ts";
import type { Finding, Tier } from "../types.ts";

export { HOME, isRed, RED_PATTERNS };

export const MAX_AGENT_DELETE_BYTES = 50 * 1024 ** 3;
export const PERMITTED_TIERS: Record<"green" | "yellow", Tier[]> = {
  green: ["green"],
  yellow: ["green", "yellow"],
};

export class AgentRefusal extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AgentRefusal";
  }
}

export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB", "PB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  const rounded = unit === 0 ? Math.round(value) : value >= 100 ? Math.round(value) : value.toFixed(1);
  return `${rounded} ${units[unit] ?? "B"}`;
}

export function displayPath(path: string): string {
  return path.split(HOME).join("~") || path;
}

export function assertAgentCanDelete(ruleIds: string[], confirm: boolean): void {
  if (!Array.isArray(ruleIds) || ruleIds.length === 0) {
    throw new AgentRefusal(
      'apply needs at least one rule id. Call scan first, then pass rule_ids from its result, for example rule_ids: ["npm.cacache"].',
    );
  }
  if (confirm !== true) {
    throw new AgentRefusal(
      "Refusing to delete: confirm is not exactly true, so this call is a refusal and nothing was removed. " +
        "Show the user the plan from this response, then re-send the identical request with confirm: true ONLY " +
        "after the user has approved that exact byte count. Never set confirm on your own initiative.",
    );
  }
}

export function assertNoUnknownRules(ruleIds: string[], known: Iterable<string>): void {
  const set = known instanceof Set ? known : new Set(known);
  const unknown = ruleIds.filter((id) => !set.has(id));
  if (unknown.length) {
    throw new AgentRefusal(
      `Unknown rule id(s): ${unknown.join(", ")}. Call list_rules for the valid ids, or scan to see what exists on this machine.`,
    );
  }
}

export function assertTierPermitted(finding: Finding, tier: "green" | "yellow"): void {
  const permitted = PERMITTED_TIERS[tier];
  if (!permitted.includes(finding.tier)) {
    throw new AgentRefusal(
      `${finding.ruleId} at ${finding.path} is tier ${finding.tier}, but this call permits only ${permitted.join("/")}. ` +
        'Re-send with tier: "yellow" only if the user explicitly approves yellow items. Red items can never be deleted.',
    );
  }
}

export function assertPathDeletable(finding: Finding): void {
  const guard = realGuard(finding.path);
  if ("refused" in guard) {
    throw new AgentRefusal(
      `${finding.path} matches the permanent red blocklist (Keychain, Mail, iCloud, git internals, Documents, Desktop, Pictures, SQLite WAL). ` +
        "This guard is hard-coded and cannot be disabled by any parameter.",
    );
  }
  const full = resolve(finding.path);
  if (full === resolve(HOME) || resolve(HOME).startsWith(full + sep)) {
    throw new AgentRefusal(`${finding.path} is HOME or a parent of HOME.`);
  }
  if (full === parse(full).root) {
    throw new AgentRefusal(`${finding.path} is the filesystem root.`);
  }
}

export function assertNotBlocked(finding: Finding): void {
  if (!finding.blocked) return;
  throw new AgentRefusal(
    `${finding.ruleId} at ${finding.path} FAILED verification, so it is hard-blocked: ${finding.note || "verification failed"}. ` +
      "Scan again and let the user resolve the cause before asking to delete anything here. Nothing is deleted on a failed verification.",
  );
}

export function assertWithinAgentCap(findings: Finding[], allowLarge: boolean): number {
  const bytes = findings.reduce((total, finding) => total + finding.bytes, 0);
  if (allowLarge === true || bytes <= MAX_AGENT_DELETE_BYTES) return bytes;
  throw new AgentRefusal(
    `Refusing to delete ${formatBytes(bytes)}: over the hard agent cap of ${formatBytes(MAX_AGENT_DELETE_BYTES)}. ` +
      "Split the request into smaller batches of rule_ids, or ask the user to approve passing allow_large: true.",
  );
}

export function table(head: string[], rows: string[][]): string {
  const cell = (row: string[], index: number): string => row[index] ?? "";
  const widths = head.map((label, index) => Math.max(label.length, ...rows.map((row) => cell(row, index).length), 1));
  const line = (row: string[]): string =>
    head
      .map((_, index) => cell(row, index).padEnd(widths[index] ?? 1))
      .join("  ")
      .trimEnd();
  const rule = widths.map((width) => "-".repeat(width));
  return [line(head), line(rule), ...rows.map(line)].join("\n");
}
