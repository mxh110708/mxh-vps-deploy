#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_ROLE:?}"
: "${VPS_PARAM_SSH_PRIMARY:?}"
: "${VPS_PARAM_SSH_RESCUE:?}"
: "${VPS_PARAM_KOMARI_ENABLED:?}"

sshd -t
effective="$(sshd -T)"
grep -qx "port ${VPS_PARAM_SSH_PRIMARY}" <<<"$effective"
grep -qx "port ${VPS_PARAM_SSH_RESCUE}" <<<"$effective"
grep -qx 'passwordauthentication no' <<<"$effective"
grep -qx 'kbdinteractiveauthentication no' <<<"$effective"
grep -qx 'pubkeyauthentication yes' <<<"$effective"
systemctl is-active --quiet nftables.service
nft -c -f /etc/nftables.conf

if [[ "$VPS_PARAM_ROLE" == 'RealityEntry' ]]; then
  : "${VPS_PARAM_XRAY_PRIMARY:?}"
  : "${VPS_PARAM_XRAY_BACKUP:?}"
  /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
  systemctl is-active --quiet xray.service
  ss -H -lntp "sport = :${VPS_PARAM_XRAY_PRIMARY}" | grep -q xray
  ss -H -lntp "sport = :${VPS_PARAM_XRAY_BACKUP}" | grep -q xray
fi

if [[ "$VPS_PARAM_KOMARI_ENABLED" == 'true' ]]; then
  systemctl is-active --quiet komari-agent.service
  [[ "$(stat -c '%a' /etc/komari-agent/config.json)" == '600' ]]
  ! ss -H -lntup 2>/dev/null | grep -q komari-agent
fi

time_state="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
printf 'VPSDEPLOY_TIME_SYNC_B64=%s\n' "$(printf '%s' "$time_state" | base64 | tr -d '\n')"
printf 'VPSDEPLOY_FINAL_OK\n'
