import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Rule } from "../types.ts";
import { exists } from "./paths.ts";

const PLATFORM_KEYS = ["all", "mac", "win", "linux"];
const TIERS = ["green", "yellow"];

export function configDir(): string {
  return join(process.env["XDG_CONFIG_HOME"] || join(homedir(), ".config"), "dustless");
}

export function userRulesPath(): string {
  return join(configDir(), "rules.yaml");
}

export async function loadRules(file?: string): Promise<Rule[]> {
  const bundled = normalize((await import("./default-rules.yaml")).default, "default-rules.yaml");
  const source = file ?? userRulesPath();
  if (!(await exists(source))) {
    if (file) throw new Error(`không tìm thấy file rules: ${source}`);
    return bundled;
  }
  const custom = normalize(parseYaml(await readFile(source, "utf8"), source), source);
  const overridden = new Set(custom.map((rule) => rule.id));
  return [...bundled.filter((rule) => !overridden.has(rule.id)), ...custom];
}

function parseYaml(text: string, file: string): unknown {
  try {
    return Bun.YAML.parse(text);
  } catch (err) {
    throw new Error(`${file}: ${(err as Error).message}`);
  }
}

function normalize(raw: unknown, file: string): Rule[] {
  if (!Array.isArray(raw)) throw new Error(`${file}: rules phải là một YAML list`);
  const broken: string[] = [];
  const rules: Rule[] = [];
  for (const item of raw) {
    const rule = (item ?? {}) as Record<string, unknown>;
    const problem = defect(rule);
    if (problem) broken.push(`${String(rule["id"] ?? "<thiếu id>")}: ${problem}`);
    else rules.push(rule as unknown as Rule);
  }
  if (broken.length) throw new Error(`${file}: rule không hợp lệ\n  - ${broken.join("\n  - ")}`);
  const seen = new Set<string>();
  return rules.filter((rule) => !seen.has(rule.id) && !!seen.add(rule.id));
}

function defect(rule: Record<string, unknown>): string | null {
  if (typeof rule["id"] !== "string" || !rule["id"]) return "thiếu id";
  if (typeof rule["desc"] !== "string" || !rule["desc"]) return "thiếu desc";
  if (!TIERS.includes(String(rule["tier"]))) {
    return `tier phải là ${TIERS.join("|")} (đang là ${JSON.stringify(rule["tier"])})`;
  }
  const paths = rule["paths"];
  if (typeof paths !== "object" || paths === null || Array.isArray(paths)) return "thiếu paths";
  for (const [key, value] of Object.entries(paths)) {
    if (!PLATFORM_KEYS.includes(key)) return `paths.${key} không phải mac|win|linux|all`;
    const list = Array.isArray(value) ? value : [value];
    if (!list.length || list.some((entry) => typeof entry !== "string" || !entry.trim())) {
      return `paths.${key} phải là string hoặc list string không rỗng`;
    }
  }
  return null;
}