#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_CONFIG_JSON:?}"
: "${VPS_PARAM_LANDING_PORT:?}"

config='/etc/sing-box/config.json'
stamp="$(date -u +%Y%m%d-%H%M%S)"
backup_dir="/root/vps-deploy-backups/${stamp}/sing-box"
install -d -m 0700 "$backup_dir"
if [[ -f "$config" ]]; then cp -a "$config" "$backup_dir/config.json"; fi
if [[ -f /etc/systemd/system/sing-box.service ]]; then
  cp -a /etc/systemd/system/sing-box.service "$backup_dir/sing-box.service"
fi

temporary="$(mktemp)"
trap 'rm -f "$temporary"' EXIT
printf '%s' "$VPS_PARAM_CONFIG_JSON" > "$temporary"
python3 -m json.tool "$temporary" >/dev/null
install -o root -g sing-box -m 0640 "$temporary" "$config"
/usr/local/bin/sing-box check -c "$config"
systemctl enable sing-box.service
systemctl restart sing-box.service
systemctl is-active --quiet sing-box.service
sleep 1
ss -H -lntp "sport = :${VPS_PARAM_LANDING_PORT}" | grep -q sing-box || {
  echo 'sing-box TCP listener is missing.' >&2
  exit 1
}
ss -H -lnup "sport = :${VPS_PARAM_LANDING_PORT}" | grep -q sing-box || {
  echo 'sing-box UDP listener is missing.' >&2
  exit 1
}
printf 'VPSDEPLOY_BACKUP_DIR_B64=%s\n' "$(printf '%s' "$backup_dir" | base64 | tr -d '\n')"
