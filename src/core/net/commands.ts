import type { Platform } from "../../types.ts";
import type { NetInfo } from "./inspect.ts";

export type NetOpId =
  | "flush-dns"
  | "reset-dns"
  | "renew-dhcp"
  | "clear-arp"
  | "reset-mtu"
  | "flush-routing";

export type Op = {
  id: NetOpId;
  label: string;
  advanced: boolean;
  root: boolean;
  targetsInterface: boolean;
  canInterrupt: boolean;
  reversible: string;
  effect: string;
};

export type Step = { cmd: string; args: string[] };

export const OPS: Op[] = [
  {
    id: "flush-dns",
    label: "flush the DNS cache",
    advanced: false,
    root: false,
    targetsInterface: false,
    canInterrupt: false,
    reversible: "self-healing: the cache repopulates from the resolvers",
    effect: "clears stale cached DNS answers",
  },
  {
    id: "reset-dns",
    label: "reset DNS servers to DHCP-provided values",
    advanced: true,
    root: true,
    targetsInterface: true,
    canInterrupt: true,
    reversible: "self-healing: DHCP repopulates the resolvers",
    effect: "drops manually-set DNS servers, restoring DHCP-provided ones",
  },
  {
    id: "renew-dhcp",
    label: "renew the DHCP lease",
    advanced: true,
    root: true,
    targetsInterface: true,
    canInterrupt: true,
    reversible: "self-healing: a fresh lease is requested immediately",
    effect: "requests a fresh IP lease; fixes stale or broken addresses",
  },
  {
    id: "clear-arp",
    label: "clear the ARP cache",
    advanced: true,
    root: true,
    targetsInterface: false,
    canInterrupt: false,
    reversible: "self-healing: neighbours are re-learned on next contact",
    effect: "removes stale neighbour (IP-to-MAC) mappings",
  },
  {
    id: "reset-mtu",
    label: "reset MTU to the default (1500)",
    advanced: true,
    root: true,
    targetsInterface: true,
    canInterrupt: true,
    reversible: "reversible: set it back if you had a non-standard value",
    effect: "sets the interface MTU to the Ethernet/Wi-Fi default",
  },
  {
    id: "flush-routing",
    label: "flush stale routing-cache entries",
    advanced: true,
    root: true,
    targetsInterface: false,
    canInterrupt: false,
    reversible: "self-healing: the route cache is rebuilt on demand",
    effect: "clears the kernel route cache (Linux only)",
  },
];

export function buildSteps(id: NetOpId, info: NetInfo, p: Platform): Step[] {
  switch (id) {
    case "flush-dns":
      if (p === "mac") {
        return [
          { cmd: "dscacheutil", args: ["-flushcache"] },
          { cmd: "killall", args: ["-HUP", "mDNSResponder"] },
        ];
      }
      if (p === "win") return [{ cmd: "ipconfig", args: ["/flushdns"] }];
      return [{ cmd: "resolvectl", args: ["flush-caches"] }];
    case "reset-dns":
      if (p === "mac") return [{ cmd: "networksetup", args: ["-setdnsservers", info.service, "Empty"] }];
      if (p === "win") {
        return [{ cmd: "netsh", args: ["interface", "ip", "set", "dnsservers", `name=${info.iface ?? ""}`, "source=dhcp"] }];
      }
      return [{ cmd: "resolvectl", args: ["revert", info.iface ?? ""] }];
    case "renew-dhcp":
      if (p === "mac") return [{ cmd: "ipconfig", args: ["set", info.iface ?? "", "DHCP"] }];
      if (p === "win") return [{ cmd: "ipconfig", args: ["/renew"] }];
      return [
        { cmd: "dhclient", args: ["-r", info.iface ?? ""] },
        { cmd: "dhclient", args: [info.iface ?? ""] },
      ];
    case "clear-arp":
      if (p === "mac") return [{ cmd: "arp", args: ["-d", "-a"] }];
      if (p === "win") return [{ cmd: "arp", args: ["-d", "*"] }];
      return [{ cmd: "ip", args: ["-s", "-s", "neigh", "flush", "all"] }];
    case "reset-mtu":
      if (p === "mac") return [{ cmd: "networksetup", args: ["-setMTU", info.service, "1500"] }];
      if (p === "win") {
        return [{ cmd: "netsh", args: ["interface", "ipv4", "set", "subinterface", info.iface ?? "", "mtu=1500", "store=persistent"] }];
      }
      return [{ cmd: "ip", args: ["link", "set", info.iface ?? "", "mtu", "1500"] }];
    case "flush-routing":
      if (p === "linux") return [{ cmd: "ip", args: ["route", "flush", "cache"] }];
      return [];
  }
}
