#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_SOURCE_ROLE:?}"
: "${VPS_PARAM_TARGET_ROLE:?}"
: "${VPS_PARAM_TARGET_PORT:?}"
target_aux_port="${VPS_PARAM_TARGET_AUX_PORT:-}"

service_for_role() {
  case "$1" in
    RealityEntry) printf '%s' 'xray.service' ;;
    AnyTlsEntry) printf '%s' 'sing-box-anytls.service' ;;
    ShadowsocksLanding) printf '%s' 'sing-box.service' ;;
    *) exit 1 ;;
  esac
}
source_service="$(service_for_role "$VPS_PARAM_SOURCE_ROLE")"
target_service="$(service_for_role "$VPS_PARAM_TARGET_ROLE")"
[[ "$source_service" != "$target_service" ]]
systemctl is-active --quiet "$target_service"

case "$VPS_PARAM_TARGET_ROLE" in
  RealityEntry)
    /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
    ss -H -lntp 'sport = :443' | grep -Fq xray
    [[ -n "$target_aux_port" ]]
    ss -H -lntp "sport = :${target_aux_port}" | grep -Fq xray
    ;;
  AnyTlsEntry)
    /usr/local/bin/sing-box-anytls check -c /etc/sing-box-anytls/config.json
    ss -H -lntp 'sport = :443' | grep -Fq sing-box-anytl
    ;;
  ShadowsocksLanding)
    /usr/local/bin/sing-box check -c /etc/sing-box/config.json
    ss -H -lntp "sport = :${VPS_PARAM_TARGET_PORT}" | grep -Fq sing-box
    ss -H -lnup "sport = :${VPS_PARAM_TARGET_PORT}" | grep -Fq sing-box
    ;;
esac

systemctl disable --now "$source_service" >/dev/null 2>&1 || true
if systemctl is-active --quiet "$source_service"; then exit 1; fi
systemctl is-active --quiet "$target_service"
systemctl stop mxh-protocol-migration-rollback.timer
systemctl disable mxh-protocol-migration-rollback.timer >/dev/null
if systemctl is-active --quiet mxh-protocol-migration-rollback.timer; then exit 1; fi
printf '%s\n' 'VPSDEPLOY_MIGRATION_COMMITTED'
