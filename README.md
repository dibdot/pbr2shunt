# pbr2shunt - migrate a pbr configuration to shunt

`pbr2shunt.sh` reads an existing `pbr` configuration and writes an equivalent `shunt` configuration. It is a one-shot helper for moving over, not part of the shunt package. pbr's config and a running shunt are never touched: the result goes to stdout or to a file of your choice, and everything that could not be carried over is reported on stderr.

## Usage

```sh
pbr2shunt.sh [-c <confdir>] [-o <file>]
```

| Option | Description |
| :--- | :--- |
| `-c` | UCI config directory to read `pbr` from, default `/etc/config` |
| `-o` | write the shunt config to `<file>` instead of stdout |

Typical run on the router:

```sh
sh pbr2shunt.sh -o /tmp/shunt.new
# read the report, review /tmp/shunt.new, then
cp /etc/config/shunt /etc/config/shunt.bak
cp /tmp/shunt.new /etc/config/shunt
service shunt restart
```

Exit codes: `0` everything migrated, `1` fatal error, `2` done, but sections or options were skipped - see the report.

The script needs `/lib/functions.sh` and `/sbin/uci`, so it runs on OpenWrt (busybox ash). Plain dash does not work, OpenWrt's `functions.sh` relies on `export -n`.

## What is migrated

| pbr | shunt |
| :--- | :--- |
| `config.lan_device` | `global.snoop_device` |
| `config.strict_enforcement '1'` (default) | `fallback 'block'` on every routing policy, otherwise `fallback 'main'` |
| policy `name` | section name, reduced to `[A-Za-z0-9_]{1,24}` and made unique (`_2`, ...) |
| policy `enabled` | `enabled '0'` where pbr had it disabled |
| `interface 'ignore'` | `action 'bypass'` |
| `interface '<name>'` (default `wan`) | `interface '<name>'` |
| `src_addr` addresses / CIDRs | `list src` |
| `src_addr` MAC addresses | `list src_mac`, dash notation rewritten to colons |
| `dest_addr` addresses / CIDRs | `list dst` |
| `dest_addr` domains | `list domain` - with `resolver_set 'dnsmasq.nftset'` as `name` plus `*.name`, because dnsmasq includes subdomains; with `none` as `name` only, matching pbr's one-shot resolve |
| `dest_port` | `list dport` |
| `proto` `tcp` / `udp` | `list proto`; `auto` / `all` are dropped |

Policy order is kept. Both pbr and shunt stop at the first matching policy, so precedence carries over unchanged. `keep_local` stays at its default: pbr already consults `main` with `suppress_prefixlength` ahead of its policy rules.

## What is not migrated

A policy containing any of the following is skipped as a whole, with the reason in the report - dropping just the offending part would silently widen or change what the policy matches:

* `src_port` - shunt has no source port selector
* negation (`!...`) - shunt has none; express the exception as a `bypass` policy above it
* `proto` other than tcp / udp (`icmp`, ...)
* hostnames in `src_addr` - use the client's address or `src_mac`
* physical devices (`@dev`) in `src_addr` or `dest_addr`
* URLs in `src_addr` or `dest_addr` - fetch the list outside shunt and use `domain_file`
* `interface 'tor'` and `xray_*` - for xray, write a `tproxy` policy by hand
* policies without any source or destination selector - pbr rejects them
* `dest_port` without any address, MAC or domain - shunt refuses a policy that selects by port alone
* `chain 'forward'` or `chain 'output'` - shunt has no chain selector, the policy would match forwarded and router traffic alike
* entries shunt would reject itself: malformed addresses, ports outside 1-65535, ranges that run backwards

Also reported, globally: enabled `dns_policy` and `include` sections, `icmp_interface`, and non-zero `<iface>_dscp` options. None of them has a shunt equivalent.

## Notes

* shunt routes IPv4 and IPv6 alike. If pbr had `ipv6_enabled '0'`, policies selecting by `src_mac` or domain now steer IPv6 traffic as well - check that their interface carries IPv6, otherwise that traffic is lost in the tunnel.
* pbr's default `prerouting` chain never touched the router's own traffic. shunt applies address and domain policies in `output` too, so a policy without a client selector now also covers traffic the router itself generates.
* Disabled pbr policies are migrated with `enabled '0'` and marked `(disabled)` in the report.
* pbr and shunt can run side by side during the move - their marks, rule priorities and tables do not overlap, and where both match pbr wins. Retire pbr once everything is verified, e.g. with `shunt check`.
