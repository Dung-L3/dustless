import { readdir, readFile, writeFile } from "node:fs/promises";
import { join, relative } from "node:path";
import ts from "typescript";
import { ROOT } from "./lib.ts";

type Finding = { file: string; message: string };

const BASELINE = join(ROOT, "scripts/repo-policy-baseline.txt");
const CODE_DIRS = ["src", "scripts", "tests", "apps/dustless-mac/Sources", "apps/dustless-mac/Tests"];
const SIZE_DIRS = ["src", "scripts", "apps/dustless-mac/Sources", "apps/dustless-mac/Tests"];
const DOC_FILES = [
  "README.md",
  "README.vi.md",
  "README.zh.md",
  "CONTRIBUTING.md",
  "docs/ARCHITECTURE.md",
  "docs/DECISIONS.md",
  "docs/MCP.md",
  "docs/MEMORY.md",
  "docs/NETWORK.md",
  "docs/PACKAGING.md",
  "docs/THREAT-MODEL.md",
];
const DATA_TABLES = new Set(["apps/dustless-mac/Sources/DustlessKit/Model/Localization.swift"]);
const DOC_LINE_REFERENCE = /\.(ts|swift|yaml|yml|nsi):[0-9]+/g;

type Baseline = { unusedKeys: Set<string>; oversize: Map<string, number>; docRefs: Map<string, number> };

async function readBaseline(): Promise<Baseline> {
  const unusedKeys = new Set<string>();
  const oversize = new Map<string, number>();
  const docRefs = new Map<string, number>();
  let section = "";
  let text = "";
  try {
    text = await readFile(BASELINE, "utf8");
  } catch {
    return { unusedKeys, oversize, docRefs };
  }
  for (const line of text.split("\n")) {
    if (line.startsWith("[")) {
      section = line.trim().toLowerCase();
      continue;
    }
    const trimmed = line.trim();
    if (!trimmed) continue;
    if (section === "[unused-localization-keys]") unusedKeys.add(trimmed);
    else if (section === "[oversize-files]") {
      const [file, count] = trimmed.split(/\s+/);
      if (file && count) oversize.set(file, Number(count));
    } else if (section === "[doc-line-references]") {
      const [file, count] = trimmed.split(/\s+/);
      if (file && count) docRefs.set(file, Number(count));
    }
  }
  return { unusedKeys, oversize, docRefs };
}

async function walk(dir: string, out: string[]): Promise<string[]> {
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === "node_modules" || entry.name === ".build" || entry.name === "dist") continue;
      await walk(full, out);
    } else if (entry.isFile() && /\.(ts|tsx|swift)$/.test(entry.name)) {
      out.push(full);
    }
  }
  return out;
}

async function collectCodeFiles(dirs: string[] = CODE_DIRS): Promise<string[]> {
  const files: string[] = [];
  for (const dir of dirs) await walk(join(ROOT, dir), files);
  return files;
}

function typescriptCommentLines(text: string): number[] {
  const source = ts.createSourceFile("check.ts", text, ts.ScriptTarget.Latest, true);
  const lines = new Set<number>();
  const visit = (node: ts.Node): void => {
    if (node.kind === ts.SyntaxKind.SingleLineCommentTrivia || node.kind === ts.SyntaxKind.MultiLineCommentTrivia) {
      const { line } = source.getLineAndCharacterOfPosition(node.getStart(source));
      lines.add(line + 1);
    }
    ts.forEachChild(node, visit);
  };
  ts.forEachChild(source, visit);
  return [...lines];
}

function swiftCommentLines(text: string): number[] {
  const lines: number[] = [];
  text.split("\n").forEach((line, index) => {
    let inString = false;
    for (let at = 0; at < line.length; at += 1) {
      const char = line[at];
      if (char === "\\" && inString) {
        at += 1;
        continue;
      }
      if (char === '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (char !== "/") continue;
      const next = line[at + 1];
      if (next === "/" || next === "*") {
        lines.push(index + 1);
        return;
      }
    }
  });
  return lines;
}

async function checkNoComments(files: string[], findings: Finding[]): Promise<void> {
  for (const file of files) {
    const text = await readFile(file, "utf8");
    const hits = file.endsWith(".swift") ? swiftCommentLines(text) : typescriptCommentLines(text);
    for (const line of hits) {
      findings.push({ file: relative(ROOT, file), message: `line ${line} has a comment` });
    }
  }
}

async function checkFileSize(baseline: Baseline, findings: Finding[]): Promise<void> {
  for (const file of await collectCodeFiles(SIZE_DIRS)) {
    const rel = relative(ROOT, file);
    if (DATA_TABLES.has(rel)) continue;
    const lines = (await readFile(file, "utf8")).split("\n").length;
    if (lines <= 500) continue;
    const allowed = baseline.oversize.get(rel);
    if (allowed === undefined) {
      findings.push({ file: rel, message: `${lines} lines exceeds the 500 line limit` });
    } else if (lines > allowed) {
      findings.push({ file: rel, message: `${lines} lines grew past the recorded ${allowed}` });
    }
  }
}

async function checkLocalizationKeys(baseline: Baseline, findings: Finding[]): Promise<void> {
  const table = await readFile(
    join(ROOT, "apps/dustless-mac/Sources/DustlessKit/Model/Localization.swift"),
    "utf8",
  );
  const keys = new Set<string>();
  for (const match of table.matchAll(/^\s+"([A-Za-z0-9._]+)":/gm)) {
    if (match[1]) keys.add(match[1]);
  }
  const sources = await collectCodeFiles();
  let used = "";
  for (const file of sources) {
    if (file.endsWith("Localization.swift")) continue;
    used += await readFile(file, "utf8");
  }
  const composed = new Set<string>();
  for (const match of used.matchAll(/"([^"\n]*?)\\\(/g)) {
    if (match[1]) composed.add(match[1]);
  }
  for (const key of keys) {
    if (used.includes(`"${key}"`)) continue;
    if ([...composed].some((prefix) => key.startsWith(prefix))) continue;
    if (baseline.unusedKeys.has(key)) continue;
    findings.push({ file: "Localization.swift", message: `key "${key}" is never used` });
  }
}

async function checkDocReferences(baseline: Baseline, findings: Finding[]): Promise<void> {
  for (const file of DOC_FILES) {
    let text: string;
    try {
      text = await readFile(join(ROOT, file), "utf8");
    } catch {
      continue;
    }
    const count = (text.match(DOC_LINE_REFERENCE) ?? []).length;
    const budget = baseline.docRefs.get(file) ?? 0;
    if (count > budget) {
      findings.push({
        file,
        message: `${count} path:line references exceed the recorded budget of ${budget}`,
      });
    }
  }
}

async function writeBaseline(): Promise<void> {
  const table = await readFile(
    join(ROOT, "apps/dustless-mac/Sources/DustlessKit/Model/Localization.swift"),
    "utf8",
  );
  const keys = new Set<string>();
  for (const match of table.matchAll(/^\s+"([A-Za-z0-9._]+)":/gm)) {
    if (match[1]) keys.add(match[1]);
  }
  const sources = await collectCodeFiles();
  let used = "";
  for (const file of sources) {
    if (file.endsWith("Localization.swift")) continue;
    used += await readFile(file, "utf8");
  }
  const unused = [...keys].filter((key) => !used.includes(`"${key}"`)).sort();
  const oversize: string[] = [];
  for (const file of await collectCodeFiles(SIZE_DIRS)) {
    const rel = relative(ROOT, file);
    if (DATA_TABLES.has(rel)) continue;
    const lines = (await readFile(file, "utf8")).split("\n").length;
    if (lines > 500) oversize.push(`${rel} ${lines}`);
  }
  const docs: string[] = [];
  for (const file of DOC_FILES) {
    let text: string;
    try {
      text = await readFile(join(ROOT, file), "utf8");
    } catch {
      continue;
    }
    const count = (text.match(DOC_LINE_REFERENCE) ?? []).length;
    if (count > 0) docs.push(`${file} ${count}`);
  }
  const body = [
    "[unused-localization-keys]",
    ...unused,
    "[oversize-files]",
    ...oversize.sort(),
    "[doc-line-references]",
    ...docs,
    "",
  ].join("\n");
  await writeFile(BASELINE, body);
  process.stdout.write(`baseline written with ${unused.length} unused keys\n`);
}

const baseline = await readBaseline();
if (process.argv.includes("--write-baseline")) {
  await writeBaseline();
  process.exit(0);
}

const files = await collectCodeFiles();
const findings: Finding[] = [];
await checkNoComments(files, findings);
await checkFileSize(baseline, findings);
await checkLocalizationKeys(baseline, findings);
await checkDocReferences(baseline, findings);

if (findings.length > 0) {
  for (const finding of findings) process.stderr.write(`${finding.file}: ${finding.message}\n`);
  process.stderr.write(`\n${findings.length} repository policy violation(s)\n`);
  process.exit(1);
}
process.stdout.write("repository policy checks passed\n");
