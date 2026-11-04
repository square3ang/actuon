#!/bin/sh
# Safe to rerun: it replaces the list. SSH is not touched.
set -eu
list=$(curl -fsS --max-time 30 https://www.cloudflare.com/ips-v4; echo; curl -fsS --max-time 30 https://www.cloudflare.com/ips-v6)
# A bad answer must not lock the proxy out, so the old list stays unless this one looks right.
ranges=$(printf '%s\n' "$list" | grep -E '^[0-9a-f:.]+/[0-9]+$')
[ "$(printf '%s\n' "$ranges" | wc -l)" -ge 10 ] || { echo "unexpected Cloudflare address list" >&2; exit 1; }
[ "$(printf '%s\n' "$list" | grep -c .)" = "$(printf '%s\n' "$ranges" | wc -l)" ] || { echo "unexpected Cloudflare address list" >&2; exit 1; }

firewall-cmd --permanent --get-zones | grep -qw cloudflare || firewall-cmd -q --permanent --new-zone=cloudflare
for old in $(firewall-cmd --permanent --zone=cloudflare --list-sources); do
	firewall-cmd -q --permanent --zone=cloudflare --remove-source="$old"
done
for range in $ranges; do
	firewall-cmd -q --permanent --zone=cloudflare --add-source="$range"
done
firewall-cmd -q --permanent --zone=cloudflare --add-service=http --add-service=https
firewall-cmd -q --permanent --zone=public --remove-service=http --remove-service=https
firewall-cmd -q --reload
