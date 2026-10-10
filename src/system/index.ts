import { readdir, stat } from "node:fs/promises";
import { join } from "node:path";
import { platform, expand } from "../core/paths.ts";
import { collectStartupItems, type StartupItem } from "./startup.ts";

export type HygieneItem = {
  id: string;
  kind: "startup" | "toolchain";
  label: string;
  detail: string;
  ageDays: number | null;
  severity: "info" | "warn";
};

export type HygieneReport = {
  items: HygieneItem[];
  startupCount: number;
  toolchainCount: number;
};

export async function inspectSystem(): Promise<HygieneReport> {
  const startup = await collectStartupItems();
  const toolchains = await inspectToolchains();
  const items = [
    ...startup.map(startupToHygiene),
    ...toolchains,
  ].sort((a, b) => (b.ageDays ?? 0) - (a.ageDays ?? 0));
  return {
    items,
    startupCount: startup.length,
    toolchainCount: toolchains.length,
  };
}

function startupToHygiene(s: StartupItem): HygieneItem {
  return {
    id: s.id,
    kind: "startup",
    label: s.label,
    detail: `${s.source} · ${s.location}`,
    ageDays: s.ageDays,
    severity: s.ageDays !== null && s.ageDays > 365 ? "warn" : "info",
  };
}

async function inspectToolchains(): Promise<HygieneItem[]> {
  const out: HygieneItem[] = [];
  for (const [id, base] of Object.entries(TOOLCHAIN_ROOTS)) {
    for (const version of await listVersions(base)) {
      const age = await ageOf(join(base, version));
      out.push({
        id: `${id}:${version}`,
        kind: "toolchain",
        label: `${id} ${version}`,
        detail: expand(base),
        ageDays: age,
        severity: age !== null && age > 365 ? "warn" : "info",
      });
    }
  }
  return out;
}

const TOOLCHAIN_ROOTS: Record<string, string> =
  platform === "win"
    ? { node: "%APPDATA%/nvm", fnm: "%LOCALAPPDATA%/fnm/node-versions" }
    : {
        node: "~/.nvm/versions/node",
        python: "~/.pyenv/versions",
        ruby: "~/.rbenv/versions",
        jdk: "/Library/Java/JavaVirtualMachines",
      };

async function listVersions(base: string): Promise<string[]> {
  try {
    const entries = await readdir(expand(base), { withFileTypes: true });
    return entries.filter((e) => e.isDirectory()).map((e) => e.name);
  } catch {
    return [];
  }
}

async function ageOf(path: string): Promise<number | null> {
  try {
    const s = await stat(path);
    return Math.floor((Date.now() - s.mtimeMs) / 86_400_000);
  } catch {
    return null;
  }
}