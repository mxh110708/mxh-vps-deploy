#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_REALITY_ENABLED:?}"
: "${VPS_PARAM_ANYTLS_ENABLED:?}"
: "${VPS_PARAM_SHADOWSOCKS_ENABLED:?}"
restart_role="${VPS_PARAM_RESTART_ROLE:-}"
case "$restart_role" in ''|RealityEntry|AnyTlsEntry|ShadowsocksLanding) ;; *) exit 1 ;; esac

for value in "$VPS_PARAM_REALITY_ENABLED" "$VPS_PARAM_ANYTLS_ENABLED" "$VPS_PARAM_SHADOWSOCKS_ENABLED"; do
  [[ "$value" == 'true' || "$value" == 'false' ]] || exit 1
done
[[ "$VPS_PARAM_REALITY_ENABLED" != 'true' || "$VPS_PARAM_ANYTLS_ENABLED" != 'true' ]] || {
  echo 'Reality and AnyTLS share TCP 443 and cannot both be enabled.' >&2
  exit 1
}

assert_installed() {
  local role="$1"
  case "$role" in
    RealityEntry)
      [[ -x /usr/local/bin/xray && -s /usr/local/etc/xray/config.json ]]
      systemctl cat xray.service >/dev/null
      /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
      ;;
    AnyTlsEntry)
      [[ -x /usr/local/bin/sing-box-anytls && -s /etc/sing-box-anytls/config.json ]]
      systemctl cat sing-box-anytls.service >/dev/null
      /usr/local/bin/sing-box-anytls check -c /etc/sing-box-anytls/config.json
      ;;
    ShadowsocksLanding)
      [[ -x /usr/local/bin/sing-box && -s /etc/sing-box/config.json ]]
      systemctl cat sing-box.service >/dev/null
      /usr/local/bin/sing-box check -c /etc/sing-box/config.json
      ;;
  esac
}

[[ "$VPS_PARAM_REALITY_ENABLED" == 'false' ]] || assert_installed RealityEntry
[[ "$VPS_PARAM_ANYTLS_ENABLED" == 'false' ]] || assert_installed AnyTlsEntry
[[ "$VPS_PARAM_SHADOWSOCKS_ENABLED" == 'false' ]] || assert_installed ShadowsocksLanding

# Stop conflicting entry services before starting the selected TCP-443 owner.
if [[ "$VPS_PARAM_REALITY_ENABLED" == 'false' ]]; then
  systemctl disable --now xray.service >/dev/null 2>&1 || true
fi
if [[ "$VPS_PARAM_ANYTLS_ENABLED" == 'false' ]]; then
  systemctl disable --now sing-box-anytls.service >/dev/null 2>&1 || true
fi
if [[ "$VPS_PARAM_SHADOWSOCKS_ENABLED" == 'false' ]]; then
  systemctl disable --now sing-box.service >/dev/null 2>&1 || true
fi

if [[ "$VPS_PARAM_REALITY_ENABLED" == 'true' ]]; then
  systemctl disable --now sing-box-anytls.service >/dev/null 2>&1 || true
  systemctl enable --now xray.service >/dev/null
fi
if [[ "$VPS_PARAM_ANYTLS_ENABLED" == 'true' ]]; then
  systemctl disable --now xray.service >/dev/null 2>&1 || true
  systemctl enable --now sing-box-anytls.service >/dev/null
fi
if [[ "$VPS_PARAM_SHADOWSOCKS_ENABLED" == 'true' ]]; then
  systemctl enable --now sing-box.service >/dev/null
fi

check_state() {
  local service="$1"
  local expected="$2"
  if [[ "$expected" == 'true' ]]; then
    systemctl is-enabled --quiet "$service"
    systemctl is-active --quiet "$service"
  else
    ! systemctl is-enabled --quiet "$service" 2>/dev/null
    ! systemctl is-active --quiet "$service" 2>/dev/null
  fi
}
case "$restart_role" in
  RealityEntry) [[ "$VPS_PARAM_REALITY_ENABLED" == true ]]; systemctl restart xray.service ;;
  AnyTlsEntry) [[ "$VPS_PARAM_ANYTLS_ENABLED" == true ]]; systemctl restart sing-box-anytls.service ;;
  ShadowsocksLanding) [[ "$VPS_PARAM_SHADOWSOCKS_ENABLED" == true ]]; systemctl restart sing-box.service ;;
esac
check_state xray.service "$VPS_PARAM_REALITY_ENABLED"
check_state sing-box-anytls.service "$VPS_PARAM_ANYTLS_ENABLED"
check_state sing-box.service "$VPS_PARAM_SHADOWSOCKS_ENABLED"

if [[ -n "$restart_role" ]]; then
  case "$restart_role" in
    RealityEntry) service=xray.service; binary=/usr/local/bin/xray ;;
    AnyTlsEntry) service=sing-box-anytls.service; binary=/usr/local/bin/sing-box-anytls ;;
    ShadowsocksLanding) service=sing-box.service; binary=/usr/local/bin/sing-box ;;
  esac
  pid="$(systemctl show "$service" -p MainPID --value)"
  [[ "$pid" =~ ^[1-9][0-9]*$ && "/proc/$pid/exe" -ef "$binary" ]] || {
    echo 'The running process does not match the installed binary.' >&2; exit 1
  }
fi

printf '%s\n' 'VPSDEPLOY_PROTOCOL_STATE_APPLIED'
