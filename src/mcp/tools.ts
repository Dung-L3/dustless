import { statfs } from "node:fs/promises";
import { homedir, release, version } from "node:os";
import { exists, HOME } from "../core/paths.ts";
import { describeReason } from "../core/messages.ts";
import { userRulesPath } from "../core/rules.ts";
import { accountedBytes, isNested } from "../core/space.ts";
import type { ApplyReport, Finding, Rule, ScanReport, Tier, TierChoice, TierStat } from "../types.ts";
import {
  AgentRefusal, assertAgentCanDelete, assertNoUnknownRules, assertNotBlocked,
  assertPathDeletable, assertTierPermitted, assertWithinAgentCap, displayPath,
  formatBytes, MAX_AGENT_DELETE_BYTES, PERMITTED_TIERS, table,
} from "./safety.ts";

export type Core = {
  scan: (opts?: { roots?: string[]; minBytes?: number }) => Promise<ScanReport>;
  apply: (report: ScanReport, opts?: { tiers?: TierChoice; assumeYes?: boolean }) => Promise<ApplyReport>;
  loadRules: () => Promise<Rule[]>;
  freeSpace: (path?: string) => Promise<number>;
};

export type ToolResult = {
  content: Array<{ type: "text"; text: string }>;
  structuredContent?: Record<string, unknown>;
  isError?: boolean;
};

export type Tool = {
  name: string;
  description: string;
  inputSchema: { type: "object"; properties: Record<string, Record<string, unknown>>; required: string[]; additionalProperties: false };
  run: (args: Record<string, unknown>) => Promise<ToolResult>;
};

type RuleSummary = {
  rule_id: string; tier: Tier; bytes: number; count: number; verified: boolean; blocked: boolean; note: string; paths: string[]; paths_hidden: number;
};

type Totals = Record<Tier, TierStat>;

const PATHS_SHOWN = 4;

function collect(problems: string[], label: string, guard: () => void): void {
  try {
    guard();
  } catch (err) {
    problems.push(`${label}: ${(err as Error).message}`);
  }
}

function ok(body: string, structured?: Record<string, unknown>, isError = false): ToolResult {
  return { content: [{ type: "text", text: body }], structuredContent: structured, isError };
}

function optString(args: Record<string, unknown>, key: string): string | undefined {
  const value = args[key];
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "string" || !value.trim()) throw new AgentRefusal(`${key} must be a non-empty string.`);
  return value;
}

function optEnum<T extends string>(args: Record<string, unknown>, key: string, allowed: readonly T[], fallback: T): T {
  const value = optString(args, key);
  if (value === undefined) return fallback;
  if (!allowed.includes(value as T)) throw new AgentRefusal(`${key} must be one of: ${allowed.join(", ")}.`);
  return value as T;
}

function optNumber(args: Record<string, unknown>, key: string): number {
  const value = args[key];
  if (value === undefined || value === null) return 0;
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) throw new AgentRefusal(`${key} must be a number >= 0.`);
  return value;
}

function optBoolean(args: Record<string, unknown>, key: string, fallback: boolean): boolean {
  const value = args[key];
  if (value === undefined || value === null) return fallback;
  if (typeof value !== "boolean") throw new AgentRefusal(`${key} must be true or false.`);
  return value;
}

function optList(args: Record<string, unknown>, key: string): string[] {
  const value = args[key];
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value) || value.some((entry) => typeof entry !== "string" || !entry.trim())) {
    throw new AgentRefusal(`${key} must be an array of non-empty strings.`);
  }
  return value as string[];
}

async function totalBytes(path: string): Promise<number> {
  const stats = await statfs(path).catch(() => null);
  return stats ? Number(stats.blocks) * Number(stats.bsize) : 0;
}

function sumOf(findings: Finding[]): number { return findings.reduce((total, finding) => total + finding.bytes, 0); }

function summarize(findings: Finding[]): RuleSummary[] {
  const byRule = new Map<string, Finding[]>();
  for (const finding of findings) byRule.set(finding.ruleId, [...(byRule.get(finding.ruleId) ?? []), finding]);
  return [...byRule.entries()]
    .sort((a, b) => sumOf(b[1]) - sumOf(a[1]))
    .map(([rule_id, found]) => ({
      rule_id, tier: found[0]?.tier ?? "green", bytes: sumOf(found), count: found.length,
      verified: found.every((finding) => finding.verified), blocked: found.some((finding) => finding.blocked),
      note: found.map((finding) => finding.note).filter(Boolean).join(" | "),
      paths: found.slice(0, PATHS_SHOWN).map((finding) => finding.path),
      paths_hidden: Math.max(0, found.length - PATHS_SHOWN),
    }));
}

function summaryRow(summary: RuleSummary): string[] {
  const tier = summary.blocked ? `BLOCKED ${summary.tier}` : summary.tier;
  const more = summary.count > 1 ? ` (+${summary.count - 1} more)` : "";
  return [summary.rule_id, tier, String(summary.count), formatBytes(summary.bytes), displayPath(summary.paths[0] ?? "") + more];
}

function tally(seed: Totals, findings: Finding[]): Totals {
  const totals = {} as Totals;
  for (const tier of Object.keys(seed) as Tier[]) totals[tier] = { count: 0, bytes: 0 };
  for (const finding of findings) {
    const key = finding.blocked ? "blocked" : finding.tier;
    const bucket = (totals[key] ??= { count: 0, bytes: 0 });
    bucket.count += 1;
    if (key === "blocked" || key === "red") bucket.bytes += finding.bytes;
  }
  const claimed: string[] = [];
  const counted = new Set<string>();
  for (const finding of [...findings]
    .filter((entry) => !entry.blocked && (entry.tier === "green" || entry.tier === "yellow"))
    .sort((a, b) => a.path.length - b.path.length)) {
    if (claimed.some((parent) => isNested(finding.path, parent))) continue;
    claimed.push(finding.path);
    counted.add(finding.path);
  }
  for (const finding of findings) {
    const key = finding.blocked ? "blocked" : finding.tier;
    if (key !== "blocked" && key !== "red" && counted.has(finding.path)) totals[key].bytes += finding.bytes;
  }
  return totals;
}

async function scanTool(core: Core, args: Record<string, unknown>): Promise<ToolResult> {
  const ruleId = optString(args, "rule_id");
  const roots = optList(args, "roots");
  const report = await core.scan({ roots: roots.length ? roots : undefined, minBytes: optNumber(args, "min_bytes") });
  const findings = ruleId ? report.findings.filter((finding) => finding.ruleId === ruleId) : report.findings;
  if (ruleId && !findings.length) {
    return ok(
      `No findings for rule_id "${ruleId}". It may not exist, or nothing matched on this machine. Call list_rules for valid ids, or scan without rule_id.`,
      { rule_id: ruleId, findings_total: report.findings.length }, true,
    );
  }
  const summaries = summarize(findings);
  const totals = tally(report.totals, findings);
  const reclaimable = accountedBytes(
    findings
      .filter((finding) => !finding.blocked && (finding.tier === "green" || finding.tier === "yellow"))
      .map((finding) => ({ path: finding.path, bytes: finding.bytes })),
  );
  const body = [
    `Dustless scan - ${report.platform}, ${report.scannedMs}ms, ${findings.length} of ${report.findings.length} findings. Nothing was deleted.`,
    table(["rule_id", "tier", "items", "size", "path"], summaries.map(summaryRow)),
    table(["tier", "items", "size"], Object.keys(totals).map((tier) => [
      tier, String(totals[tier as Tier].count), formatBytes(totals[tier as Tier].bytes),
    ])),
    `Free before: ${formatBytes(report.freeBefore)}. Reclaimable: ${formatBytes(reclaimable)}.`,
    ruleId ? "" : "Next: call apply with rule_ids. It refuses to delete unless you also pass confirm: true.",
  ].join("\n\n");
  return ok(body, {
    scanned_ms: report.scannedMs, findings_total: report.findings.length, findings_shown: findings.length,
    free_before: report.freeBefore, reclaimable, totals, rules: summaries,
  });
}

async function applyTool(core: Core, args: Record<string, unknown>): Promise<ToolResult> {
  const ruleIds = optList(args, "rule_ids");
  const tier = optEnum(args, "tier", ["green", "yellow"] as const, "green");
  const confirm = optBoolean(args, "confirm", false);
  const allowLarge = optBoolean(args, "allow_large", false);
  const [report, rules] = await Promise.all([core.scan(), core.loadRules()]);
  const selected = report.findings.filter((finding) => ruleIds.includes(finding.ruleId));
  const problems: string[] = [];
  collect(problems, "rule ids", () => assertNoUnknownRules(ruleIds, rules.map((rule) => rule.id)));
  collect(problems, "tier", () => selected.forEach((finding) => assertTierPermitted(finding, tier)));
  collect(problems, "red-path guard", () => selected.forEach((finding) => assertPathDeletable(finding)));
  collect(problems, "verification", () => selected.forEach((finding) => assertNotBlocked(finding)));
  collect(problems, "size cap", () => assertWithinAgentCap(selected, allowLarge));
  collect(problems, "confirmation", () => assertAgentCanDelete(ruleIds, confirm));
  if (!selected.length) problems.push("targets: no requested rule id matched anything. Call scan and use ids from its result.");
  const bytes = accountedBytes(selected.map((finding) => ({ path: finding.path, bytes: finding.bytes })));
  const plan = {
    requested: ruleIds, tier, permitted_tiers: PERMITTED_TIERS[tier], confirm, allow_large: allowLarge, total_bytes: bytes,
    would_delete: selected.map((finding) => ({
      rule_id: finding.ruleId, tier: finding.tier, path: finding.path, bytes: finding.bytes, verified: finding.verified, note: finding.note,
    })),
    no_matches: ruleIds.filter((id) => !selected.some((finding) => finding.ruleId === id)),
    problems,
  };
  if (problems.length) {
    return ok([
      "REFUSED - nothing was deleted.",
      ...problems.map((problem) => `- ${problem}`),
      `${selected.length} finding(s), ${formatBytes(bytes)}, would be deleted once every problem above is resolved.`,
      "Apply is all-or-nothing. Fix every problem, then re-send the identical request with confirm: true.",
    ].join("\n\n"), plan, true);
  }
  const tiers: TierChoice = {};
  for (const finding of selected) {
    if (finding.tier === "yellow") tiers[finding.ruleId] = "yellow";
    else if (!Object.hasOwn(tiers, finding.ruleId)) tiers[finding.ruleId] = "green";
  }
  const result = await core.apply({ ...report, findings: selected }, { tiers, assumeYes: true });
  const notDeleted = result.outcomes.filter((outcome) => outcome.status !== "deleted");
  const body = [
    `Deleted ${result.outcomes.length - notDeleted.length} of ${result.outcomes.length} finding(s) (${formatBytes(result.deletedBytes)}). ` +
      `Freed ${formatBytes(result.freed)} of volume space in ${result.elapsedMs}ms.`,
    table(["rule_id", "tier", "status", "bytes", "path", "detail"], result.outcomes.map((outcome) => [
      outcome.ruleId, outcome.tier, outcome.status, formatBytes(outcome.bytes), displayPath(outcome.path),
      outcome.detail ? describeReason(outcome.detail) : "-",
    ])),
    notDeleted.length ? `${notDeleted.length} finding(s) were NOT deleted - see the detail column.` : "All requested findings were deleted.",
  ].join("\n\n");
  return ok(body, {
    freed: result.freed, free_before: result.freeBefore, free_after: result.freeAfter, elapsed_ms: result.elapsedMs,
    deleted: result.outcomes.filter((outcome) => outcome.status === "deleted").map((outcome) => ({ rule_id: outcome.ruleId, path: outcome.path, bytes: outcome.bytes })),
    not_deleted: notDeleted.map((outcome) => ({
      rule_id: outcome.ruleId,
      path: outcome.path,
      status: outcome.status,
      detail: outcome.detail ? describeReason(outcome.detail) : "",
    })),
  });}

async function listRulesTool(core: Core, args: Record<string, unknown>): Promise<ToolResult> {
  const only = optEnum<string>(args, "tier", ["green", "yellow"], "all");
  const rules = (await core.loadRules()).filter((rule) => only === "all" || rule.tier === only);
  return ok([
    `${rules.length} rules. Sizes are only known after scan.`,
    table(["rule_id", "tier", "paths", "description"], rules.map((rule) => [
      rule.id, rule.tier, Object.values(rule.paths).flat().join(" "), rule.desc,
    ])),
  ].join("\n\n"), { count: rules.length, rules });
}

async function freeSpaceTool(core: Core, args: Record<string, unknown>): Promise<ToolResult> {
  const path = optString(args, "path") ?? homedir();
  const [free, total] = await Promise.all([core.freeSpace(path), totalBytes(path)]);
  const used = total > free ? total - free : 0;
  const percentUsed = total > 0 ? Math.round((used / total) * 1000) / 10 : 0;
  return ok(`${path}: ${formatBytes(free)} free of ${formatBytes(total)} (${percentUsed}% used).`, {
    path, free, total, used, percent_used: percentUsed,
  });
}

async function doctorTool(core: Core): Promise<ToolResult> {
  const rules = await core.loadRules();
  const checks = {
    platform: process.platform,
    "os.version": `${release()} (${version()})`,
    runtime: typeof Bun === "undefined" ? "node" : `bun ${Bun.version}`,
    cwd: process.cwd(),
    home: HOME,
    "rules.file": userRulesPath(),
    "rules.file_exists": await exists(userRulesPath()),
    "rules.loaded": rules.length,
    "rules.green": rules.filter((rule) => rule.tier === "green").length,
    "rules.yellow": rules.filter((rule) => rule.tier === "yellow").length,
    "disk.free": await core.freeSpace(HOME),
    "disk.total": await totalBytes(HOME),
    "safety.confirm_required": true,
    "safety.max_delete_bytes": MAX_AGENT_DELETE_BYTES,
    "safety.red_list_blocked": true,
  };
  return ok(`Dustless doctor\n\n${table(["key", "value"], Object.entries(checks).map(([key, value]) => [key, String(value)]))}`, checks);
}

function shape(properties: Record<string, Record<string, unknown>>, required: string[] = []): Tool["inputSchema"] {
  return { type: "object", properties, required, additionalProperties: false };
}

function prop(type: string, description: string, extra: Record<string, unknown> = {}): Record<string, unknown> {
  return { type, description, default: null, ...extra };
}

export function createTools(core: Core): Tool[] {
  return [
    {
      name: "scan",
      description: "Read-only. Measures every cache directory in the Dustless rule database and returns a COMPACT per-rule summary (rule id, tier, item count, size, example path) plus per-tier totals and how much disk is reclaimable. Deletes nothing and mutates nothing. Call this first: it is the only way to learn which rule_ids exist and how large they are. Results are aggregated per rule, not per file, to keep the context small. Red-tier findings, and any finding marked BLOCKED because its verification failed, are listed for visibility but can never be deleted.",
      inputSchema: shape({
        rule_id: prop("string", "Only report this single rule id. Omit for every rule."),
        min_bytes: prop("number", "Ignore findings smaller than this many bytes.", { minimum: 0, default: 0 }),
        roots: prop("array", "Restrict the scan to paths under these directories.", { items: { type: "string" }, default: [] }),
      }),
      run: (args) => scanTool(core, args),
    },
    {
      name: "apply",
      description: "Delete cache. REFUSES TO DELETE BY DEFAULT: nothing is removed unless confirm is exactly true. Always call scan first, show the user this exact plan, and only re-send with confirm: true after the user has explicitly approved that byte count - never set confirm on your own initiative. Scans fresh, then deletes only the findings whose rule_id you list, and only those at a tier you permitted via tier (green = regenerable caches, the default; yellow = items that may still be in use, so require explicit human approval). Red items can never be deleted under any parameters. All-or-nothing: if ANY requested rule is unknown, red, above the permitted tier, or the batch is over 50 GB without allow_large, the whole call is refused and NOTHING is deleted - the response lists every problem. allow_large: true still requires confirm: true.",
      inputSchema: shape({
        rule_ids: prop("array", "Exact rule ids to delete, as returned by scan. Anything not listed here is never touched.", { items: { type: "string" }, minItems: 1 }),
        tier: prop("string", "Highest tier you may delete. 'green' deletes only regenerable caches. 'yellow' also deletes items that may still be in use, and needs the user's explicit approval.", { enum: ["green", "yellow"], default: "green" }),
        confirm: prop("boolean", "Must be true to delete anything. False (the default) makes this a dry run that returns the plan and deletes nothing.", { default: false }),
        allow_large: prop("boolean", "Raise the hard 50 GB per-call cap, only after the user approved the total size in bytes. Does NOT bypass confirm or the red-path guard.", { default: false }),
      }, ["rule_ids"]),
      run: (args) => applyTool(core, args),
    },
    {
      name: "list_rules",
      description: "Read-only. Returns the Dustless rule database: every rule id, its safety tier and what it matches. Tier meanings - green: pure regenerable cache, safe to delete; yellow: may still be in use (VM images, emulator AVDs, build output), needs human approval; red: real user data (Keychain, Mail, iCloud, git internals, Documents, Desktop, Pictures), permanently blocked from deletion. Use it to discover valid rule_ids for scan and apply without touching the disk.",
      inputSchema: shape({
        tier: prop("string", "Only list rules at this tier. Omit to list every rule.", { enum: ["green", "yellow"] }),
      }),
      run: (args) => listRulesTool(core, args),
    },
    {
      name: "free_space",
      description: "Read-only. Returns current free, total and used bytes on the filesystem holding your home directory, or any path you pass. Use it before a cleanup to establish a baseline and after apply to confirm the space was actually reclaimed.",
      inputSchema: shape({ path: prop("string", "Directory whose filesystem should be measured. Defaults to the home directory.") }),
      run: (args) => freeSpaceTool(core, args),
    },
    {
      name: "doctor",
      description: "Read-only environment diagnostics: platform and OS version, runtime version, where the rule database is loaded from and how many rules it holds, free and total disk bytes, and the safety limits you are bound by (explicit confirmation required, 50 GB per-call cap, red-path blocklist). Use it when scan or apply fails unexpectedly, or to confirm the server is wired up correctly before touching anything.",
      inputSchema: shape({}),
      run: () => doctorTool(core),
    },
  ];
}
