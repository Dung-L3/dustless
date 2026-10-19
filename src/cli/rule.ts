import { appendFile, mkdir } from "node:fs/promises";
import { writeOut } from "../core/output.ts";
import { exists } from "../core/paths.ts";
import { configDir, defect, loadRules, userRulesPath } from "../core/rules.ts";
import { flag, say, tierBadge } from "./context.ts";

export async function runRule(sub: string, rest: string[]): Promise<number> {
  if (sub === "list") {
    const rules = await loadRules();
    if (flag("json")) {
      await writeOut(`${JSON.stringify(rules)}\n`);
      return 0;
    }
    for (const rule of rules) say(`${tierBadge(rule.tier)} ${rule.id.padEnd(26)} ${rule.desc}`);
    const source = (await exists(userRulesPath())) ? userRulesPath() : "default-rules.yaml";
    say(`\n${rules.length} rule · nguồn: ${source}`);
    return 0;
  }
  if (sub === "show") {
    const found = (await loadRules()).find((rule) => rule.id === rest[0]);
    if (!found) throw new Error(`không có rule "${rest[0] ?? ""}"`);
    await writeOut(`${JSON.stringify(found, null, 2)}\n`);
    return 0;
  }

  if (sub === "add") {
    const [id, tier, desc, recovery, ...patterns] = rest;
    if (!id || !tier || !desc || !recovery || !patterns.length) {
      throw new Error("dùng: dustless rule add <id> <green|yellow> <desc> <download|rebuild> <path>");
    }
    if (recovery !== "download" && recovery !== "rebuild") {
      throw new Error("recovery phải là download hoặc rebuild");
    }
    const problem = defect({ id, tier, desc, recoveryLabel: recovery, paths: { all: patterns } }, false);
    if (problem) throw new Error(`rule không hợp lệ: ${problem}`);
    await mkdir(configDir(), { recursive: true });
    const paths = patterns.map((path) => `    all: ${JSON.stringify(path)}`).join("\n");
    await appendFile(userRulesPath(), `\n- id: ${JSON.stringify(id)}\n  tier: ${tier}\n  desc: ${JSON.stringify(desc)}\n  recoveryLabel: ${recovery}\n  paths:\n${paths}\n`);
    say(`đã thêm ${id} vào ${userRulesPath()} (${(await loadRules()).length} rule hợp lệ)`);
    return 0;
  }
  if (sub === "validate") {
    const rules = await loadRules(rest[0]);
    if (flag("json")) {
      await writeOut(`${JSON.stringify({ ok: true, rules: rules.length })}\n`);
      return 0;
    }
    say(`OK — ${rules.length} rule hợp lệ`);
    for (const rule of rules) say(`  ${rule.id.padEnd(26)} ${rule.recoveryLabel ?? "—"}`);
    return 0;
  }
  throw new Error(`rule: lệnh con không hợp lệ "${sub}"`);
}
