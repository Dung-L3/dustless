import { readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { platform, HOME, expand } from "../core/paths.ts";

const exec = promisify(execFile);

export type StartupItem = {
  id: string;
  label: string;
  source: "launchagent" | "launchdaemon" | "loginitem" | "runkey" | "startupfolder";
  location: string;
  lastRun: number | null;
  ageDays: number | null;
  target: string | null;
  exists: boolean;
  note: string;
};

export async function collectStartupItems(): Promise<StartupItem[]> {
  return platform === "mac" ? collectMac() : platform === "win" ? collectWindows() : [];
}

async function collectMac(): Promise<StartupItem[]> {
  const items: StartupItem[] = [];
  items.push(...(await scanPlistDir("~/Library/LaunchAgents", "launchagent")));
  items.push(...(await scanPlistDir("/Library/LaunchAgents", "launchagent")));
  items.push(...(await scanPlistDir("/Library/LaunchDaemons", "launchdaemon")));
  return items;
}

async function scanPlistDir(
  dir: string,
  source: StartupItem["source"],
): Promise<StartupItem[]> {
  const full = expand(dir);
  let names: string[];
  try {
    names = await readdir(full);
  } catch {
    return [];
  }
  const items: Promise<StartupItem | null>[] = [];
  for (const name of names.filter((n) => n.endsWith(".plist"))) {
    items.push(readPlist(join(full, name), source));
  }
  return (await Promise.all(items)).filter((x): x is StartupItem => x !== null);
}

async function readPlist(
  path: string,
  source: StartupItem["source"],
): Promise<StartupItem | null> {
  const label = path.split(/[/\\]/).pop()!.replace(/\.plist$/, "");
  let target: string | null = null;
  let ageDays: number | null = null;
  let lastRun: number | null = null;
  try {
    const text = await readFile(path, "utf8");
    target = pick(text, /<key>Program<\/key>\s*<string>([^<]+)<\/string>/)
      ?? pick(text, /<key>ProgramArguments<\/key>\s*<array>\s*<string>([^<]+)<\/string>/);
    const start = pick(text, /<key>StartInterval<\/key>\s*<integer>(\d+)<\/integer>/);
    lastRun = start ? Date.now() - Number(start) * 1000 : null;
    ageDays = await dirAgeDays(path);
  } catch {
    ageDays = null;
  }
  return {
    id: `plist:${label}`,
    label,
    source,
    location: path,
    lastRun,
    ageDays,
    target,
    exists: target !== null,
    note: staleNote(ageDays),
  };
}

async function collectWindows(): Promise<StartupItem[]> {
  const items: StartupItem[] = [];
  const keys = [
    ["HKCU", "Software\\Microsoft\\Windows\\CurrentVersion\\Run"],
    ["HKLM", "Software\\Microsoft\\Windows\\CurrentVersion\\Run"],
  ] as const;
  for (const [hive, sub] of keys) {
    items.push(...(await readRunKey(hive, sub)));
  }
  for (const [dir, source] of [
    [expand("%APPDATA%/Microsoft/Windows/Start Menu/Programs/Startup"), "startupfolder"],
  ] as const) {
    let names: string[];
    try {
      names = await readdir(dir);
    } catch {
      continue;
    }
    for (const name of names.filter((n) => /\.(lnk|url|exe|bat|cmd)$/i.test(n))) {
      const p = join(dir, name);
      items.push({
        id: `startup:${name}`,
        label: name,
        source,
        location: p,
        lastRun: null,
        ageDays: await dirAgeDays(p),
        target: null,
        exists: true,
        note: "startup folder entry",
      });
    }
  }
  return items;
}

async function readRunKey(hive: string, sub: string): Promise<StartupItem[]> {
  let stdout: string;
  try {
    ({ stdout } = await exec("reg", ["query", `${hive}\\${sub}`], {
      timeout: 5000,
      windowsHide: true,
    }));
  } catch {
    return [];
  }
  const items: StartupItem[] = [];
  for (const line of stdout.split(/\r?\n/)) {
    const m = line.match(/^\s+(.+?)\s+REG_(?:SZ|EXPAND_SZ)\s+(.+)$/);
    const label = m?.[1]?.trim();
    const target = m?.[2]?.trim();
    if (!label || !target) continue;
    items.push({
      id: `runkey:${label}`,
      label,
      source: "runkey",
      location: `${hive}\\${sub}\\${label}`,
      lastRun: null,
      ageDays: null,
      target,
      exists: true,
      note: "registry Run key",
    });
  }
  return items;
}

function pick(text: string, re: RegExp): string | null {
  return text.match(re)?.[1] ?? null;
}

async function dirAgeDays(path: string): Promise<number | null> {
  try {
    const s = await stat(path);
    return Math.floor((Date.now() - s.mtimeMs) / 86_400_000);
  } catch {
    return null;
  }
}

function staleNote(ageDays: number | null): string {
  if (ageDays === null) return "không đọc được thời gian sửa";
  if (ageDays > 365) return `không chạm tới ${Math.floor(ageDays / 365)} năm`;
  if (ageDays > 90) return `không chạm tới ${Math.floor(ageDays / 30)} tháng`;
  return "còn mới";
}

export const STARTUP_LOCATIONS: Record<string, string> = {
  mac: `${HOME}/Library/LaunchAgents`,
  win: "%APPDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\Startup",
  linux: `${HOME}/.config/autostart`,
};