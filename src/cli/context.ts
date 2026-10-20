import pkg from "../../package.json" with { type: "json" };
import { args as readArgs } from "../core/args.ts";
import { writeOut } from "../core/output.ts";
import type { Tier } from "../types.ts";

export const VERSION = pkg.version;
export const ICON: Record<Tier, string> = { green: "🟢", yellow: "🟡", red: "🔴", blocked: "⛔" };
export const HUE: Record<Tier, string> = { green: "32", yellow: "33", red: "31", blocked: "35" };
export const KEY_PATHS = [
  "~/.config/dustless",
  "~/.gradle/caches",
  "~/.npm/_cacache",
  "~/Library/Caches",
  "~/Library/Mail",
];

export const HELP = `dustless ${VERSION} — dọn cache máy dev, không xóa mù

  dustless scan                 quét chéo, in ra những gì có thể dọn
  dustless apply                xóa GREEN, hỏi từng mục YELLOW
  dustless apply --only-file <selection.json>  chỉ xóa đúng các path trong mảng JSON này
  dustless rule list|show|add|validate
  dustless mcp                 chạy MCP server trên stdio (cho AI agent)
  dustless doctor               chẩn đoán môi trường
  dustless net                  flush DNS cache; --reset-dns v.v. là nâng cao, từng lệnh một
  dustless net --print-privilege   in quy tắc sudo giới hạn cho thao tác nâng cao (không cần root)
  dustless awdl [--json]        trạng thái AWDL (AirDrop); --off | --on để tắt/bật
  dustless ram [--list]         quản lý bộ nhớ (chỉ xem, không tự động hành động)
  dustless apps [--json]        liệt kê ứng dụng .app
  dustless apps --uninstall <path> --confirm [--purge] [--json]  gỡ ứng dụng (di chuyển đến Thùng rác)
  dustless largefiles [--json] [--min-size 200mb] [--limit 50]  liệt kê tệp lớn nhất trong thư mục home
  dustless largefiles --delete <path> --confirm [--json]  chuyển một tệp sang Thùng rác (không xóa vĩnh viễn; từ chối danh sách đỏ)
  dustless version | help

Cờ chung: --json (máy đọc) --quiet (ít chữ, không giấu lỗi) --yes (không hỏi)`;

const argv = process.argv.slice(2);
export const args = readArgs(argv);
export const flag = args.flag;
export const opt = args.opt;

const color = process.stdout.isTTY === true && !process.env["NO_COLOR"];
export const paint = (hue: string, text: string): string => (color ? `\x1b[${hue}m${text}\x1b[0m` : text);
export const bold = (text: string): string => paint("1", text);
export const dim = (text: string): string => paint("2", text);

export function bytesOf(n: number): string {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = n;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${unit === 0 ? value : value.toFixed(1)} ${units[unit] ?? "B"}`;
}

export function tierBadge(tier: Tier): string {
  return paint(HUE[tier], `${ICON[tier]} ${tier.toUpperCase()}`);
}

export function say(line = ""): void {
  if (!flag("quiet")) console.log(line);
}

export function errorOut(line: string): void {
  console.error(paint("31", line));
}

export async function fail(message: string): Promise<number> {
  if (flag("json")) await writeOut(`${JSON.stringify({ error: message })}\n`);
  else errorOut(`✖ ${message}`);
  return 1;
}

export function required(name: string, usage: string): string {
  const value = opt(name);
  if (value === undefined) throw new Error(`cần một giá trị cho --${name} — ${usage}`);
  return value;
}

const GLOBAL_FLAGS = ["json", "quiet", "yes", "help", "version"] as const;
const COMMAND_FLAGS: Record<string, readonly string[]> = {
  scan: [],
  apply: ["only-file"],
  rule: [],
  doctor: [],
  net: ["advanced", "flush-dns", "reset-dns", "renew-dhcp", "clear-arp", "reset-mtu", "flush-routing", "dry-run", "force", "print-privilege"],
  awdl: ["on", "off", "print-privilege"],
  ram: ["list", "kill", "confirm", "force", "sigkill", "filter", "sort"],
  apps: ["uninstall", "confirm", "purge", "trash-dir"],
  largefiles: ["min-size", "limit", "delete", "confirm", "trash-dir"],
  mcp: [],
  version: [],
  help: [],
};

export function unknownFlag(command: string): string | null {
  const allowed = new Set<string>([...GLOBAL_FLAGS, ...(COMMAND_FLAGS[command] ?? [])]);
  for (const token of argv) {
    if (!token.startsWith("--")) continue;
    if (!allowed.has(token.slice(2))) return token;
  }
  return null;
}

export function flushStdout(): Promise<void> {
  return new Promise((resolve) => process.stdout.write("", () => resolve()));
}
