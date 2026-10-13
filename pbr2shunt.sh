#!/bin/sh
# pbr2shunt - convert a pbr configuration into a shunt configuration
#
# Reads /etc/config/pbr, writes a complete shunt config to stdout (or -o),
# and reports everything it could not carry over to stderr. pbr and the
# running shunt are never touched.
#
# Exit: 0 = everything migrated, 1 = fatal error, 2 = done, but sections or
#       options were skipped (see report)
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Dirk Brenken <dev@brenken.org>

usage() {
	cat >&2 <<-EOF
		usage: ${0##*/} [-c <confdir>] [-o <file>]
		  -c  UCI config directory to read pbr from (default /etc/config)
		  -o  write the shunt config to <file> instead of stdout
	EOF
	exit 1
}

out=''
while getopts 'c:o:h' opt; do
	case "$opt" in
	c)
		UCI_CONFIG_DIR="$OPTARG"
		export UCI_CONFIG_DIR
		;;
	o) out="$OPTARG" ;;
	*) usage ;;
	esac
done
shift $((OPTIND - 1))
[ "$#" -eq 0 ] || usage

LC_ALL=C
export LC_ALL

[ -r /lib/functions.sh ] || {
	echo "error: /lib/functions.sh not found" >&2
	exit 1
}
. /lib/functions.sh
set -f

rc=0
names=' '
pcount=0
tmp="$(mktemp)" || exit 1
trap 'rm -f "$tmp"' EXIT
trap 'exit 1' INT TERM

warn() {
	printf '%s\n' "$*" >&2
	rc=2
}
note() { printf '%s\n' "$*" >&2; }

# single quote a UCI value
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# pbr accepts ',', ';', '{' and '}' as separators as well
words() { printf '%s' "$1" | tr ',;{}' '    '; }

is_ipv4() { printf '%s' "$1" | grep -qE '^((25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})(/(3[0-2]|[12]?[0-9]))?$'; }
is_mac() { printf '%s' "$1" | grep -qE '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'; }
is_mac_dash() { printf '%s' "$1" | grep -qE '^([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}$'; }
is_ipv6() { ! is_mac "$1" && printf '%s' "$1" | grep -qE '^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*(/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8]))?$'; }
is_domain() { printf '%s' "$1" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,61}[a-zA-Z0-9]$|^[a-zA-Z0-9]$|^([a-zA-Z0-9]([a-zA-Z0-9_-]{0,61}[a-zA-Z0-9])?\.)+([a-zA-Z]{2,}|xn--[a-zA-Z0-9-]+)$'; }
# 1-65535, a range must not run backwards - the same check shunt applies
is_port() {
	local lo hi
	printf '%s' "$1" | grep -qE '^[0-9]{1,5}(-[0-9]{1,5})?$' || return 1
	lo="${1%-*}"
	hi="${1#*-}"
	lo="${lo#${lo%%[!0]*}}"
	hi="${hi#${hi%%[!0]*}}"
	[ "${lo:-0}" -ge 1 ] && [ "${hi:-0}" -le 65535 ] && [ "${lo:-0}" -le "${hi:-0}" ]
}
is_url() {
	case "$1" in file://* | ftp://* | http://* | https://*) return 0 ;; esac
	return 1
}

# pbr policy names are free text, shunt section names are [A-Za-z0-9_]{1,24};
# sets $sname without a subshell so $names keeps track of what is taken
slug() {
	local s i=1
	s="$(printf '%s' "$1" | sed -E 's/[^A-Za-z0-9_]+/_/g; s/_+/_/g; s/^_//; s/_$//' | cut -c1-24)"
	s="${s%_}"
	[ -n "$s" ] || s="policy_$pcount"
	sname="$s"
	while case "$names" in *" $sname "*) true ;; *) false ;; esac; do
		i=$((i + 1))
		sname="$(printf '%s' "$s" | cut -c1-$((23 - ${#i})) | sed 's/_*$//')_$i"
	done
	names="$names$sname "
}

# globals
config_load pbr || {
	echo "error: no pbr config found" >&2
	exit 1
}
config_get_bool strict config strict_enforcement 1
config_get_bool ipv6 config ipv6_enabled 0
config_get resolver config resolver_set ''
config_get lan_dev config lan_device 'br-lan'
config_get icmp_if config icmp_interface ''
config_get prefixlength config prefixlength '1'

[ "$resolver" = 'none' ] && resolver=''
[ "$strict" = '1' ] && fallback='block' || fallback='main'

[ "$ipv6" = '0' ] && note "note: pbr had IPv6 disabled, shunt routes both families - policies selecting by src_mac or domain now steer IPv6 as well; check that their interface carries IPv6"
[ -n "$icmp_if" ] && warn "skip: global icmp_interface '$icmp_if' has no shunt equivalent"
[ "$prefixlength" != '0' ] && [ "$prefixlength" != '1' ] && note "note: pbr prefixlength '$prefixlength' differs, shunt keep_local uses suppress_prefixlength 0"

# per interface DSCP marking lives as <iface>_dscp in the global section
for v in $(/sbin/uci ${UCI_CONFIG_DIR:+-c "$UCI_CONFIG_DIR"} -q show pbr.config | sed -n 's/^pbr\.config\.\([A-Za-z0-9_]*_dscp\)=.*/\1/p'); do
	config_get d config "$v" '0'
	[ "$d" != '0' ] && warn "skip: global $v '$d', DSCP based routing has no shunt equivalent"
done

{
	printf 'config global\n'
	printf "\toption enabled '1'\n"
	printf "\toption poll_interval '300'\n"
	printf "\toption entry_ttl '1200'\n"
	printf "\toption snoop '1'\n"
	printf "\toption debug '0'\n"
	printf "\toption rp_filter_manage '0'\n"
	for d in $(words "$lan_dev"); do
		printf '\tlist snoop_device %s\n' "$(q "$d")"
	done
} >"$tmp"

migrate_policy() {
	local sec="$1" name enabled iface proto chain src_addr src_port dest_addr dest_port
	local e p skip='' action='route' sname dis=''
	local src='' mac='' dst='' dom='' ports='' protos=''

	pcount=$((pcount + 1))
	config_get name "$sec" name "Untitled"
	config_get_bool enabled "$sec" enabled 1
	config_get iface "$sec" interface 'wan'
	config_get proto "$sec" proto ''
	config_get chain "$sec" chain 'prerouting'
	config_get src_addr "$sec" src_addr ''
	config_get src_port "$sec" src_port ''
	config_get dest_addr "$sec" dest_addr ''
	config_get dest_port "$sec" dest_port ''

	src_addr="$(words "$src_addr")"
	src_port="$(words "$src_port")"
	dest_addr="$(words "$dest_addr")"
	dest_port="$(words "$dest_port")"
	proto="$(printf '%s' "$proto" | tr 'A-Z' 'a-z')"
	[ "$enabled" = '1' ] || dis=' (disabled)'

	_skip() {
		warn "skip: policy '$name'${dis}: $*"
		skip=1
	}

	case "$iface" in
	ignore) action='bypass' ;;
	tor) _skip "interface 'tor' (DNS/port redirect to tor) has no shunt equivalent" ;;
	xray_*) _skip "interface '$iface' - use a shunt tproxy policy with the xray tproxy port by hand" ;;
	esac

	[ -z "${src_addr}${src_port}${dest_addr}${dest_port}" ] && _skip "no source or destination selector - pbr rejects it"
	[ -n "$dest_port" ] && [ -z "${src_addr}${dest_addr}" ] && _skip "ports only - shunt needs a client, address or domain next to dport"
	[ -n "$src_port" ] && _skip "src_port '$src_port' - shunt has no source port selector"

	case "$src_addr $dest_addr $dest_port" in
	'!'* | *' !'*) _skip "negated selector - shunt has no negation, express the exception as a bypass policy above it" ;;
	esac

	for e in $src_addr; do
		case "$e" in '!'*) continue ;; esac
		if is_url "$e"; then
			_skip "src_addr URL '$e' - not supported"
		elif case "$e" in @*) true ;; *) false ;; esac; then
			_skip "src_addr device '$e' - shunt selects clients by address or MAC only"
		elif is_mac "$e"; then
			mac="$mac $(printf '%s' "$e" | tr 'A-F' 'a-f')"
		elif is_mac_dash "$e"; then
			mac="$mac $(printf '%s' "$e" | tr 'A-F-' 'a-f:')"
			note "note: policy '$name': MAC '$e' rewritten in colon notation"
		elif is_ipv4 "$e" || is_ipv6 "$e"; then
			src="$src $e"
		elif is_domain "$e"; then
			_skip "src_addr hostname '$e' - shunt needs an address or MAC (src_mac) for clients"
		else
			_skip "src_addr '$e' not understood"
		fi
	done

	for e in $dest_addr; do
		case "$e" in '!'*) continue ;; esac
		e="${e%.}"
		if is_url "$e"; then
			_skip "dest_addr URL '$e' - fetch it outside shunt and use domain_file"
		elif case "$e" in @*) true ;; *) false ;; esac; then
			_skip "dest_addr device '$e' - shunt has no output interface selector"
		elif is_ipv4 "$e" || is_ipv6 "$e"; then
			dst="$dst $e"
		elif is_domain "$e"; then
			# dnsmasq nftset covers subdomains, pbr's one shot resolve does not
			e="$(printf '%s' "$e" | tr 'A-Z' 'a-z')"
			dom="$dom $e"
			[ -n "$resolver" ] && dom="$dom *.$e"
		else
			_skip "dest_addr '$e' not understood"
		fi
	done

	for e in $dest_port; do
		case "$e" in '!'*) continue ;; esac
		is_port "$e" && ports="$ports $e" || _skip "dest_port '$e' - expected 1-65535 or a range"
	done

	for p in $proto; do
		case "$p" in
		auto | all) ;;
		tcp | udp) protos="$protos $p" ;;
		*) _skip "proto '$p' - shunt selects tcp and udp only" ;;
		esac
	done

	case "$chain" in
	'' | prerouting) ;;
	*) _skip "chain '$chain' - shunt has no chain selector, the policy would match forwarded and router traffic alike" ;;
	esac

	[ -n "$skip" ] && return 0

	slug "$name"
	{
		printf '\nconfig policy %s\n' "$(q "$sname")"
		[ "$enabled" = '1' ] || printf "\toption enabled '0'\n"
		if [ "$action" = 'bypass' ]; then
			printf "\toption action 'bypass'\n"
		else
			printf '\toption interface %s\n' "$(q "$iface")"
			printf '\toption fallback %s\n' "$(q "$fallback")"
		fi
		for e in $src; do printf '\tlist src %s\n' "$(q "$e")"; done
		for e in $mac; do printf '\tlist src_mac %s\n' "$(q "$e")"; done
		for e in $protos; do printf '\tlist proto %s\n' "$(q "$e")"; done
		for e in $ports; do printf '\tlist dport %s\n' "$(q "$e")"; done
		for e in $dst; do printf '\tlist dst %s\n' "$(q "$e")"; done
		for e in $(printf '%s\n' $dom | awk '!s[$0]++'); do printf '\tlist domain %s\n' "$(q "$e")"; done
	} >>"$tmp"

	note "ok:   policy '$name'${dis} -> '$sname'"
}

skip_section() {
	local en
	config_get_bool en "$1" enabled "$3"
	[ "$en" = '1' ] && warn "skip: $2 section '$1' has no shunt equivalent"
}

config_foreach migrate_policy policy
config_foreach skip_section dns_policy 'dns_policy' 1
config_foreach skip_section include 'include (user file)' 0

if [ -n "$out" ]; then
	cp "$tmp" "$out" || exit 1
	note "written: $out"
else
	cat "$tmp"
fi

exit "$rc"
