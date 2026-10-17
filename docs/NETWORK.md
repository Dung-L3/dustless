# Dustless `net` — network maintenance, honestly labelled

`dustless net` is a small network-maintenance command. Its design principle is the same as the
rest of Dustless: the default does the one thing that is safe and self-healing, and anything that
touches live network state is opt-in, individually named, and refuses before it can strand you.

## What runs by default

`dustless net` with no arguments does exactly three things, in this order:

1. Prints the current state: active interface, default gateway, and DNS servers (read-only).
2. Flushes the DNS cache:
   - macOS — `dscacheutil -flushcache` (works unprivileged) then `killall -HUP mDNSResponder`
     (needs root; if it fails, Dustless reports that it was skipped rather than pretending).
   - Linux — `resolvectl flush-caches`.
   - Windows — `ipconfig /flushdns`.
3. Reports exactly what ran and whether it succeeded.

No other state is changed. Nothing here can drop connectivity.

## Advanced operations (never the default)

Each of these is selected with its own flag. There is deliberately no "optimise everything" button.

| Flag | What it does | Reversible / self-healing? | Can drop connectivity? |
|---|---|---|---|
| `--reset-dns` | Reset the interface's DNS servers to DHCP-provided values | Self-healing: DHCP repopulates the resolvers | Yes — until DHCP answers, name resolution may fail |
| `--renew-dhcp` | Renew the DHCP lease | Self-healing: a fresh lease is requested immediately | Yes — the interface re-negotiates its address |
| `--clear-arp` | Clear the ARP (IP→MAC) cache | Self-healing: neighbours are re-learned on next contact | No (brief re-ARP, sub-second) |
| `--reset-mtu` | Set the interface MTU back to 1500 | Reversible, but manual: if you had a non-standard MTU for PPPoE/VPN you must set it back yourself | Yes — a wrong MTU fragments or black-holes traffic |
| `--flush-routing` | Flush the kernel route cache | Self-healing: the cache is rebuilt on demand | No |

`--flush-routing` is Linux-only. On macOS the only "flush" primitive is `route flush`, which
drops *every* route including the default one, so Dustless refuses it by design and says so.
The same is true of `route -f` on Windows.

### The guard

Any advanced operation that targets the active interface and *could* interrupt it is refused when
that interface is the **only route to the network**, unless you pass `--force`. Concretely:
`--renew-dhcp` on Wi-Fi while Wi-Fi is your sole connection will be refused; `--renew-dhcp
--force` overrides. The refusal message says why and names the interface.

### Root

The advanced operations need root (they change system state). As root they run directly. Otherwise
they run once through `sudo -n`, which fails fast instead of blocking on a password prompt, and a
refusal is reported as `refused` with the hint below — never as a raw error, and never as a silent
unprivileged retry (a network change that half-applied is worse than a clean no). The default DNS
flush is the exception: `dscacheutil -flushcache` runs unprivileged, and the `killall -HUP
mDNSResponder` half is reported as "skipped: needs root" when it fails.

### `dustless net --print-privilege` — remember the authorization once

Asking for the admin password on every advanced operation is tedious, so `dustless net
--print-privilege` prints the sudoers rule the macOS app installs for the "remember this
authorization" button in the Network panel. It needs no root: it only reads the current interface
and service. `--print-privilege --json` returns the same rule as JSON (`user`, `path`, `allowed`,
`rule`), which is what the app decodes — the app keeps no copy of the rule text.

**This is not a saved password.** Nothing here stores, sees, or re-sends your password. What gets
installed is one file, `/etc/sudoers.d/dustless-net`, granting your account exactly these four
commands for this machine's current interface and service:

```
mac ALL=(root) NOPASSWD: /usr/sbin/networksetup -setdnsservers Wi-Fi Empty, /usr/sbin/ipconfig set en0 DHCP, /usr/sbin/arp -d -a, /usr/sbin/networksetup -setMTU Wi-Fi 1500
```

Every path is absolute and every argument is exact — no wildcards, no shell, no argument
passthrough. A service name containing spaces (`USB 10/100/1000 LAN`) is double-quoted in the rule
so sudoers matches the single argument the engine actually passes; a service name containing `"`
or `#` is refused rather than escaped. Anything outside those four commands is still refused, and
the file is validated with `visudo -cf` on a staged copy before it is moved into place, so a
malformed rule can never land in `/etc/sudoers.d/`.

Because the rule names the interface and service resolved at install time, switching to a different
network means the rule no longer covers it — re-run the install step from the Network panel.

Remove it any time with `sudo rm /etc/sudoers.d/dustless-net`, or from the panel's "remove" action;
the advanced operations then ask for the password again, exactly as before.

### Dry run

`dustless net --reset-dns --dry-run` prints what *would* change (the current DNS servers and the
target: DHCP-provided values) and changes nothing. `--dry-run` never issues a write command.

## Honest positioning: what actually helps, and what is placebo

Most of what the "network acceleration" category sells does not increase bandwidth. Nothing in
`dustless net` makes a connection faster than the link allows. What the operations *do* fix, when
they help at all, is a broken or stale state, not a slow one:

**Real, measurable effect:**

- **Flushing the DNS cache** clears stale answers so a changed record (a moved domain, a new
  CDN) is re-fetched. It is a real fix for "site won't resolve after a DNS change", not a speed-up.
- **Renewing the DHCP lease** can fix a genuinely broken connection: a stale lease, an IP
  conflict, or a wrong address after switching networks.
- **Resetting DNS to DHCP** fixes a manually-misconfigured resolver (e.g. a leftover hardcoded
  DNS server that now black-holes lookups).

**Placebo for speed (still occasionally useful as repair):**

- **Clearing the ARP cache** is often sold as a speed boost. It is not — ARP entries are
  re-learned automatically and only matter after a neighbour changes its MAC. It can fix a
  stale entry after a router swap, and it is harmless, but it will not make anything faster.
- **Flushing the route cache** is the same story: the kernel rebuilds it on demand, so flushing
  it changes nothing measurable in steady state. It is only useful after a topology change.
- **Resetting the MTU** does not increase throughput. It can *fix* fragmentation on links that
  need a smaller MTU than the default, but on a normal Ethernet/Wi-Fi link 1500 is already
  correct, so "resetting" it changes nothing.

The CLI output reports what changed, not a fabricated improvement. It never prints a speed number.

## `dustless awdl` — the AirDrop radio that fights Wi-Fi

AWDL (Apple Wireless Direct Link, `awdl0`) is the peer-to-peer radio behind AirDrop, Handoff and
Universal Clipboard. On Apple silicon it timeshares the Wi-Fi chip with your normal connection, and
when it scans it shows up as periodic ping spikes and random dropouts — often blamed on the router
or the ISP until you ping the gateway and watch the spikes land on the *first* hop.

The trade is small and reversible: putting `awdl0` down keeps Wi-Fi and the internet fully working
and only stops those Apple continuity features.

| Command | What it does | Needs root? |
|---|---|---|
| `dustless awdl` | Prints the live `awdl0` state. Read-only. | No |
| `dustless awdl --off` | `ifconfig awdl0 down` — Wi-Fi stable, AirDrop off | Yes |
| `dustless awdl --on` | `ifconfig awdl0 up` — AirDrop/Handoff available again | Yes |
| `dustless awdl --print-privilege` | Prints the sudoers line the menu-bar app installs | No |

`--json` on any of them yields a machine-readable report; `--print-privilege --json` returns the
rule and the two commands it allows.

Unlike `dustless net`, the operations here do not refuse outright when they are not root: they try
`sudo -n` once, and if that fails they report `refused` with a message naming the fix. This is the
one place in Dustless that escalates, and it is scoped deliberately:

- The privilege rule lives at `/etc/sudoers.d/dustless-awdl` and permits **exactly two commands**,
  each absolute and exact — `/sbin/ifconfig awdl0 down` and `/sbin/ifconfig awdl0 up`. No wildcards,
  no shell, no argument passthrough.
- It is written by the macOS app's one-time "AirDrop toggle" setup (an admin prompt), or by hand
  from the output of `--print-privilege`. Remove it any time with
  `sudo rm /etc/sudoers.d/dustless-awdl`.
- Without the rule, `dustless awdl --off` still works when run as root.

### Honest positioning

Disabling AWDL does not make anything faster and does not change the link's ceiling. What it removes
is *interference*: the periodic radio hand-off that produced the spikes in the first place. If
pinging your gateway is clean, AWDL is not your problem and none of this will help. Measure the
first hop before believing any of it:

```
ping -c 60 -i 0.5 192.168.1.1    # your gateway, not 1.1.1.1
```

A clean LAN ping is single-digit milliseconds with near-zero jitter. Spikes here, on the hop *before*
the internet, are the signal this command addresses.
