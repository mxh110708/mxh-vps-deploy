#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_TCP_PORTS:?}"

IFS=',' read -r -a ports <<<"$VPS_PARAM_TCP_PORTS"
(( ${#ports[@]} >= 2 )) || { echo 'At least two TCP ports are required.' >&2; exit 1; }
for port in "${ports[@]}"; do
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || exit 1
done
ports_rendered="$(IFS=', '; echo "${ports[*]}")"

config='/etc/nftables.conf'
stamp="$(date -u +%Y%m%d-%H%M%S)"
backup_dir="/root/vps-deploy-backups/${stamp}/nftables"
install -d -m 0700 "$backup_dir"
if [[ -f "$config" ]]; then cp -a "$config" "$backup_dir/nftables.conf"; fi

temporary="$(mktemp)"
trap 'rm -f "$temporary"' EXIT
cat > "$temporary" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0;
    policy drop;

    iifname "lo" accept
    ct state invalid drop
    ct state established,related accept
    tcp dport { ${ports_rendered} } accept
    udp sport 67 udp dport 68 accept
    udp sport 547 udp dport 546 accept
    ip protocol icmp accept
    ip6 nexthdr ipv6-icmp accept
  }

  chain forward {
    type filter hook forward priority 0;
    policy drop;
  }

  chain output {
    type filter hook output priority 0;
    policy accept;
  }
}
EOF

nft -c -f "$temporary"
install -o root -g root -m 0755 "$temporary" "$config"
nft -f "$config"
systemctl enable nftables.service
systemctl restart nftables.service
systemctl is-active --quiet nftables.service
for port in "${ports[@]}"; do
  nft list ruleset | grep -Eq "tcp dport.*${port}" || { echo "Port missing from nftables: $port" >&2; exit 1; }
done
printf 'VPSDEPLOY_BACKUP_DIR_B64=%s\n' "$(printf '%s' "$backup_dir" | base64 | tr -d '\n')"
