#!/usr/bin/env bash
set -euo pipefail

config='/etc/sysctl.d/99-mxh-vps-deploy.conf'
stamp="$(date -u +%Y%m%d-%H%M%S)"
backup_dir="/root/vps-deploy-backups/${stamp}/sysctl"
install -d -m 0700 "$backup_dir"
if [[ -f "$config" ]]; then cp -a "$config" "$backup_dir/"; fi

modprobe tcp_bbr 2>/dev/null || true
bbr_available=false
if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
  bbr_available=true
fi

{
  echo '# Managed by MXH VPS Deploy. Conservative baseline only.'
  echo 'net.core.default_qdisc = fq'
  if [[ "$bbr_available" == true ]]; then
    echo 'net.ipv4.tcp_congestion_control = bbr'
  fi
  echo 'net.ipv4.tcp_fastopen = 3'
  echo 'net.ipv4.tcp_mtu_probing = 1'
} > "$config"

sysctl --system >/dev/null
[[ "$(sysctl -n net.core.default_qdisc)" == 'fq' ]]
if [[ "$bbr_available" == true ]]; then
  [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == 'bbr' ]]
fi
printf 'VPSDEPLOY_BBR_B64=%s\n' "$(printf '%s' "$bbr_available" | base64 | tr -d '\n')"
printf 'VPSDEPLOY_BACKUP_DIR_B64=%s\n' "$(printf '%s' "$backup_dir" | base64 | tr -d '\n')"
