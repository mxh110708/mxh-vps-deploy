#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_CONFIG_JSON:?}"
: "${VPS_PARAM_ECH_KEYS_PEM:?}"
: "${VPS_PARAM_ECH_CONFIG_PEM:?}"
: "${VPS_PARAM_PORT:?}"
: "${VPS_PARAM_SERVER_NAME:?}"

config='/etc/sing-box-anytls/config.json'
stamp="$(date -u +%Y%m%d-%H%M%S)"
backup_dir="/root/vps-deploy-backups/${stamp}/sing-box-anytls"
install -d -m 0700 "$backup_dir"
for existing in "$config" /etc/sing-box-anytls/ech-key.pem /etc/sing-box-anytls/ech-config.pem; do
  if [[ -f "$existing" ]]; then cp -a "$existing" "$backup_dir/$(basename "$existing")"; fi
done

temporary="$(mktemp)"
ech_keys_tmp="$(mktemp)"
ech_config_tmp="$(mktemp)"
xray_was_active='no'
xray_was_enabled='no'
rollback_needed='no'
cleanup() {
  local status="$?"
  rm -f "$temporary" "$ech_keys_tmp" "$ech_config_tmp"
  if [[ "$status" -ne 0 && "$rollback_needed" == 'yes' ]]; then
    set +e
    systemctl disable --now sing-box-anytls.service >/dev/null 2>&1
    if [[ "$xray_was_enabled" == 'yes' ]]; then
      systemctl enable xray.service >/dev/null 2>&1
    fi
    if [[ "$xray_was_active" == 'yes' ]]; then
      systemctl start xray.service >/dev/null 2>&1
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
printf '%s' "$VPS_PARAM_CONFIG_JSON" > "$temporary"
printf '%s' "$VPS_PARAM_ECH_KEYS_PEM" > "$ech_keys_tmp"
printf '%s' "$VPS_PARAM_ECH_CONFIG_PEM" > "$ech_config_tmp"
python3 -m json.tool "$temporary" >/dev/null
grep -Fq -- '-----BEGIN ECH KEYS-----' "$ech_keys_tmp"
grep -Fq -- '-----BEGIN ECH CONFIGS-----' "$ech_config_tmp"

install -o root -g sing-box-anytls -m 0640 "$temporary" "$config"
install -o root -g sing-box-anytls -m 0640 "$ech_keys_tmp" /etc/sing-box-anytls/ech-key.pem
install -o root -g sing-box-anytls -m 0644 "$ech_config_tmp" /etc/sing-box-anytls/ech-config.pem
chown root:sing-box-anytls /etc/mxh-tls/anytls/fullchain.pem /etc/mxh-tls/anytls/privkey.pem
chmod 0644 /etc/mxh-tls/anytls/fullchain.pem
chmod 0640 /etc/mxh-tls/anytls/privkey.pem

openssl x509 -in /etc/mxh-tls/anytls/fullchain.pem -noout -checkhost "$VPS_PARAM_SERVER_NAME" >/dev/null
/usr/local/bin/sing-box-anytls check -c "$config"

if systemctl is-active --quiet xray.service; then xray_was_active='yes'; fi
if systemctl is-enabled --quiet xray.service 2>/dev/null; then xray_was_enabled='yes'; fi
rollback_needed='yes'
if [[ "$xray_was_active" == 'yes' ]]; then systemctl stop xray.service; fi
if [[ "$xray_was_enabled" == 'yes' ]]; then systemctl disable xray.service >/dev/null; fi

systemctl enable sing-box-anytls.service >/dev/null
systemctl restart sing-box-anytls.service
systemctl is-active --quiet sing-box-anytls.service
sleep 1
ss -H -lntp "sport = :${VPS_PARAM_PORT}" | grep -F sing-box-anytl >/dev/null
if systemctl is-active --quiet xray.service; then
  echo 'xray and sing-box-anytls must not be active at the same time.' >&2
  exit 1
fi
rollback_needed='no'

printf 'VPSDEPLOY_XRAY_WAS_ACTIVE_B64=%s\n' "$(printf '%s' "$xray_was_active" | base64 | tr -d '\n')"
printf 'VPSDEPLOY_XRAY_WAS_ENABLED_B64=%s\n' "$(printf '%s' "$xray_was_enabled" | base64 | tr -d '\n')"
printf 'VPSDEPLOY_BACKUP_DIR_B64=%s\n' "$(printf '%s' "$backup_dir" | base64 | tr -d '\n')"
