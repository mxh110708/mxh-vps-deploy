#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_TARGET_ROLE:?}"
: "${VPS_PARAM_SSH_PRIMARY:?}"
: "${VPS_PARAM_SSH_RESCUE:?}"
: "${VPS_PARAM_REALITY_INSTALLED:?}"
: "${VPS_PARAM_REALITY_ENABLED:?}"
: "${VPS_PARAM_ANYTLS_INSTALLED:?}"
: "${VPS_PARAM_ANYTLS_ENABLED:?}"
: "${VPS_PARAM_SHADOWSOCKS_INSTALLED:?}"
: "${VPS_PARAM_SHADOWSOCKS_ENABLED:?}"

for value in \
  "$VPS_PARAM_REALITY_INSTALLED" "$VPS_PARAM_REALITY_ENABLED" \
  "$VPS_PARAM_ANYTLS_INSTALLED" "$VPS_PARAM_ANYTLS_ENABLED" \
  "$VPS_PARAM_SHADOWSOCKS_INSTALLED" "$VPS_PARAM_SHADOWSOCKS_ENABLED"; do
  [[ "$value" == 'true' || "$value" == 'false' ]] || exit 1
done
[[ "$VPS_PARAM_REALITY_ENABLED" != 'true' || "$VPS_PARAM_ANYTLS_ENABLED" != 'true' ]] || exit 1

systemctl is-active --quiet ssh.service
sshd -t
for port in "$VPS_PARAM_SSH_PRIMARY" "$VPS_PARAM_SSH_RESCUE"; do
  ss -H -lntp "sport = :$port" | grep -Fq sshd || { echo "sshd is not listening on $port" >&2; exit 1; }
done
if command -v nft >/dev/null 2>&1 && [[ -f /etc/nftables.conf ]]; then nft -c -f /etc/nftables.conf; fi
if systemctl is-active --quiet mxh-protocol-migration-rollback.timer 2>/dev/null; then
  echo 'An earlier protocol lifecycle rollback timer is still active.' >&2
  exit 1
fi

verify_protocol() {
  local role="$1" service="$2" binary="$3" config="$4" expected_installed="$5" expected_enabled="$6"
  local actual_installed='false' actual_enabled='false' actual_active='false'
  if [[ -x "$binary" && -s "$config" ]] && systemctl cat "$service" >/dev/null 2>&1; then actual_installed='true'; fi
  systemctl is-enabled --quiet "$service" 2>/dev/null && actual_enabled='true'
  systemctl is-active --quiet "$service" 2>/dev/null && actual_active='true'
  [[ "$actual_installed" == "$expected_installed" ]] || { echo "Installed state changed after confirmation: $role" >&2; exit 1; }
  [[ "$actual_enabled" == "$expected_enabled" ]] || { echo "Enabled state changed after confirmation: $role" >&2; exit 1; }
  [[ "$actual_active" == "$expected_enabled" ]] || { echo "Active state does not match enabled state: $role" >&2; exit 1; }
  if [[ "$actual_installed" == 'true' ]]; then
    case "$role" in
      RealityEntry) /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json ;;
      AnyTlsEntry) /usr/local/bin/sing-box-anytls check -c /etc/sing-box-anytls/config.json ;;
      ShadowsocksLanding) /usr/local/bin/sing-box check -c /etc/sing-box/config.json ;;
    esac
  fi
}

verify_protocol RealityEntry xray.service /usr/local/bin/xray /usr/local/etc/xray/config.json \
  "$VPS_PARAM_REALITY_INSTALLED" "$VPS_PARAM_REALITY_ENABLED"
verify_protocol AnyTlsEntry sing-box-anytls.service /usr/local/bin/sing-box-anytls /etc/sing-box-anytls/config.json \
  "$VPS_PARAM_ANYTLS_INSTALLED" "$VPS_PARAM_ANYTLS_ENABLED"
verify_protocol ShadowsocksLanding sing-box.service /usr/local/bin/sing-box /etc/sing-box/config.json \
  "$VPS_PARAM_SHADOWSOCKS_INSTALLED" "$VPS_PARAM_SHADOWSOCKS_ENABLED"

if [[ "$VPS_PARAM_REALITY_ENABLED" == 'true' ]]; then
  ss -H -lntp 'sport = :443' | grep -Fq xray
  if [[ -n "${VPS_PARAM_XRAY_BACKUP_PORT:-}" ]]; then
    ss -H -lntp "sport = :${VPS_PARAM_XRAY_BACKUP_PORT}" | grep -Fq xray
  fi
fi
if [[ "$VPS_PARAM_ANYTLS_ENABLED" == 'true' ]]; then
  ss -H -lntp 'sport = :443' | grep -Fq sing-box-anytl
fi
if [[ "$VPS_PARAM_SHADOWSOCKS_ENABLED" == 'true' ]]; then
  [[ -n "${VPS_PARAM_SHADOWSOCKS_PORT:-}" ]]
  ss -H -lntp "sport = :${VPS_PARAM_SHADOWSOCKS_PORT}" | grep -Fq sing-box
  ss -H -lnup "sport = :${VPS_PARAM_SHADOWSOCKS_PORT}" | grep -Fq sing-box
fi

printf '%s\n' 'VPSDEPLOY_MIGRATION_PREFLIGHT_OK'
