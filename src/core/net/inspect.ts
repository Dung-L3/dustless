import type { Platform } from "../../types.ts";
import type { Runner } from "./run.ts";

export type NetInfo = {
  iface: string | null;
  gateway: string | null;
  dns: string[];
  service: string;
  soloRoute: boolean;
};

export async function inspect(p: Platform, run: Runner): Promise<NetInfo> {
  if (p === "win") return inspectWin(run);
  if (p === "linux") return inspectLinux(run);
  return inspectMac(run);
}

async function inspectMac(run: Runner): Promise<NetInfo> {
  const route = await run("route", ["-n", "get", "default"]);
  const iface = firstMatch(route.out, /^\s*interface:\s*(\S+)/m);
  const gateway = firstMatch(route.out, /^\s*gateway:\s*(\S+)/m);
  const dnsRes = await run("scutil", ["--dns"]);
  // `scutil --dns` prints one block per resolver, and a resolver with several
  // search domains repeats the same nameservers; the user has a list of servers,
  // not a list of query scopes, so collapse the duplicates and keep the order.
  const dns = [...new Set(allMatches(dnsRes.out, /^\s*nameserver\[\d+\]\s*:\s*(\S+)/gm))];
  const ports = await run("networksetup", ["-listallhardwareports"]);
  let service = serviceFor(ports.out, iface);
  // The hardware-port list is not the whole truth: it omits services that are
  // not "hardware" in its sense (VPN, Thunderbolt Bridge, some USB), and then
  // the device is simply not in the map. `-listnetworkserviceorder` is the
  // other device → service mapping and knows them.
  if (iface && !service) {
    const order = await run("networksetup", ["-listnetworkserviceorder"]);
    service = serviceForOrder(order.out, iface);
  }
  const routes = await run("netstat", ["-rn", "-f", "inet"]);
  const defaultCount = countMatches(routes.out, /^default\s/gm);
  return { iface, gateway, dns, service, soloRoute: defaultCount <= 1 };
}

async function inspectLinux(run: Runner): Promise<NetInfo> {
  const route = await run("ip", ["route", "show", "default"]);
  const iface = firstMatch(route.out, /\sdev\s+(\S+)/);
  const gateway = firstMatch(route.out, /\svia\s+(\S+)/);
  const resolv = await run("cat", ["/etc/resolv.conf"]);
  const dns = allMatches(resolv.out, /^\s*nameserver\s+(\S+)/gm);
  const defaultCount = countMatches(route.out, /^default\s/gm);
  return { iface, gateway, dns, service: iface ?? "", soloRoute: defaultCount <= 1 };
}

async function inspectWin(run: Runner): Promise<NetInfo> {
  const route = await run("route", ["print", "0.0.0.0"]);
  const line = route.out.split(/\r?\n/).find((l) => /^\s*0\.0\.0\.0\s+0\.0\.0\.0\s/.test(l)) ?? "";
  const cols = line.trim().split(/\s+/);
  const gateway = cols[2] ?? null;
  const iface = cols[3] ?? null;
  const ipconfig = await run("ipconfig", ["/all"]);
  const dns = allMatches(ipconfig.out, /DNS Servers[^\r\n]*?:?\s*(\d+\.\d+\.\d+\.\d+)/g);
  const defaultCount = countMatches(route.out, /^\s*0\.0\.0\.0\s+0\.0\.0\.0\s/gm);
  return { iface, gateway, dns, service: iface ?? "", soloRoute: defaultCount <= 1 };
}

function firstMatch(text: string, re: RegExp): string | null {
  const m = re.exec(text);
  return m?.[1] ?? null;
}

function allMatches(text: string, re: RegExp): string[] {
  return [...text.matchAll(re)].map((m) => m[1] ?? "").filter((v) => v !== "");
}

function countMatches(text: string, re: RegExp): number {
  return text.match(re)?.length ?? 0;
}

/**
 * The hardware-port name for a device ("en0" → "Wi-Fi"), or "" when the device
 * is not listed.
 *
 * Empty rather than the raw interface name: `networksetup` is addressed by
 * *service* name and rejects a device name ("en7" is not a recognized network
 * service"), so handing one back would build a command that can only fail —
 * and a sudoers rule naming it would be permanently broken. An unresolved
 * service is a reason to refuse, not to guess.
 */
function serviceFor(text: string, iface: string | null): string {
  if (!iface) return "";
  const devices = new Map<string, string>();
  let current = "";
  for (const raw of text.split(/\r?\n/)) {
    const port = /^Hardware Port:\s*(.+)$/.exec(raw.trim());
    if (port) current = (port[1] ?? "").trim();
    const device = /^Device:\s*(\S+)$/.exec(raw.trim());
    if (device?.[1] && current) devices.set(device[1], current);
  }
  return devices.get(iface) ?? "";
}

/**
 * `networksetup -listnetworkserviceorder` prints numbered services with the
 * hardware they run on in the parenthetical under each name:
 *
 *   (1) Wi-Fi
 *   (Hardware Port: Wi-Fi, Device: en0)
 *
 *   (2) Thunderbolt Bridge
 *   (Hardware Port: Thunderbolt Bridge, Device: bridge0)
 *
 * A disabled service is marked with a trailing `(*)` on its name line.
 */
function serviceForOrder(text: string, iface: string): string {
  let current = "";
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    const named = /^\(\d+\)\s*(.+)$/.exec(line);
    if (named) {
      current = (named[1] ?? "").replace(/\s*\(\*\)\s*$/, "").trim();
      continue;
    }
    // The whole line is one parenthetical, so the device ends at the `)`.
    const device = /\bDevice:\s*([^)\s]+)/.exec(line);
    if (device?.[1] === iface && current) return current;
  }
  return "";
}
