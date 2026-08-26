#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_REMOVE_ROLE:?}"

remove_xray() {
  systemctl disable --now xray.service >/dev/null 2>&1 || true
  ! systemctl is-active --quiet xray.service 2>/dev/null
  rm -f /usr/local/bin/xray
  rm -rf /usr/local/etc/xray /usr/local/share/xray
  rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
  rm -rf /etc/systemd/system/xray.service.d
  rm -f /etc/nginx/sites-enabled/mxh-reality-target /etc/nginx/sites-available/mxh-reality-target
  rm -rf /var/www/mxh-reality-target
  if command -v nginx >/dev/null 2>&1; then
    if find /etc/nginx/sites-enabled -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
      nginx -t
      systemctl reload nginx.service >/dev/null 2>&1 || true
    else
      systemctl disable --now nginx.service >/dev/null 2>&1 || true
    fi
  fi
}

remove_anytls() {
  systemctl disable --now sing-box-anytls.service >/dev/null 2>&1 || true
  ! systemctl is-active --quiet sing-box-anytls.service 2>/dev/null
  rm -f /usr/local/bin/sing-box-anytls /etc/systemd/system/sing-box-anytls.service
  rm -rf /etc/sing-box-anytls /var/lib/sing-box-anytls
}

remove_shadowsocks() {
  systemctl disable --now sing-box.service >/dev/null 2>&1 || true
  ! systemctl is-active --quiet sing-box.service 2>/dev/null
  rm -f /usr/local/bin/sing-box /etc/systemd/system/sing-box.service
  rm -rf /etc/systemd/system/sing-box.service.d /etc/sing-box /var/lib/sing-box
}

case "$VPS_PARAM_REMOVE_ROLE" in
  RealityEntry)
    ! systemctl is-enabled --quiet xray.service 2>/dev/null
    ! systemctl is-active --quiet xray.service 2>/dev/null
    remove_xray
    ;;
  AnyTlsEntry)
    ! systemctl is-enabled --quiet sing-box-anytls.service 2>/dev/null
    ! systemctl is-active --quiet sing-box-anytls.service 2>/dev/null
    remove_anytls
    ;;
  ShadowsocksLanding)
    ! systemctl is-enabled --quiet sing-box.service 2>/dev/null
    ! systemctl is-active --quiet sing-box.service 2>/dev/null
    remove_shadowsocks
    ;;
  *)
    echo 'Unsupported protocol role.' >&2
    exit 1
    ;;
esac

systemctl daemon-reload
printf '%s\n' 'VPSDEPLOY_PROTOCOL_UNINSTALLED'
