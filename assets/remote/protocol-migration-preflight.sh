#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_SOURCE_ROLE:?}"
: "${VPS_PARAM_TARGET_ROLE:?}"
: "${VPS_PARAM_SOURCE_PORT:?}"
: "${VPS_PARAM_SSH_PRIMARY:?}"
: "${VPS_PARAM_SSH_RESCUE:?}"

service_for_role() {
  case "$1" in
    RealityEntry) printf '%s' 'xray.service' ;;
    AnyTlsEntry) printf '%s' 'sing-box-anytls.service' ;;
    ShadowsocksLanding) printf '%s' 'sing-box.service' ;;
    *) echo "Unsupported protocol role: $1" >&2; exit 1 ;;
  esac
}

source_service="$(service_for_role "$VPS_PARAM_SOURCE_ROLE")"
target_service="$(service_for_role "$VPS_PARAM_TARGET_ROLE")"
[[ "$source_service" != "$target_service" ]]
systemctl is-active --quiet "$source_service"
systemctl is-enabled --quiet "$source_service"
if systemctl is-active --quiet "$target_service"; then
  echo "Target service is already active: $target_service" >&2
  exit 1
fi
systemctl is-active --quiet ssh.service
sshd -t
for port in "$VPS_PARAM_SSH_PRIMARY" "$VPS_PARAM_SSH_RESCUE"; do
  ss -H -lntp "sport = :$port" | grep -Fq sshd || { echo "sshd is not listening on $port" >&2; exit 1; }
done
if command -v nft >/dev/null 2>&1 && [[ -f /etc/nftables.conf ]]; then
  nft -c -f /etc/nftables.conf
fi
if systemctl is-active --quiet mxh-protocol-migration-rollback.timer 2>/dev/null; then
  echo 'An earlier migration rollback timer is still active.' >&2
  exit 1
fi

case "$VPS_PARAM_SOURCE_ROLE" in
  RealityEntry)
    /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
    ss -H -lntp 'sport = :443' | grep -Fq xray
    ;;
  AnyTlsEntry)
    /usr/local/bin/sing-box-anytls check -c /etc/sing-box-anytls/config.json
    ss -H -lntp 'sport = :443' | grep -Fq sing-box-anytl
    ;;
  ShadowsocksLanding)
    /usr/local/bin/sing-box check -c /etc/sing-box/config.json
    ss -H -lntp "sport = :${VPS_PARAM_SOURCE_PORT}" | grep -Fq sing-box
    ss -H -lnup "sport = :${VPS_PARAM_SOURCE_PORT}" | grep -Fq sing-box
    ;;
esac

printf '%s\n' 'VPSDEPLOY_MIGRATION_PREFLIGHT_OK'
