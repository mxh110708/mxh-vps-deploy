#!/usr/bin/env bash
set -euo pipefail
: "${VPS_PARAM_ROLE:?}"
: "${VPS_PARAM_CONFIG_JSON:?}"
: "${VPS_PARAM_WAS_ACTIVE:?}"
[[ "$VPS_PARAM_WAS_ACTIVE" == 'true' || "$VPS_PARAM_WAS_ACTIVE" == 'false' ]]
tmp="$(mktemp --suffix=.json)"; trap 'rm -f "$tmp"' EXIT
printf '%s' "$VPS_PARAM_CONFIG_JSON" > "$tmp"
python3 -m json.tool "$tmp" >/dev/null
case "$VPS_PARAM_ROLE" in
  RealityEntry)
    /usr/local/bin/xray run -test -config "$tmp"
    group="$(id -gn "$(systemctl show xray.service -p User --value | sed '/^$/c root')")"
    install -o root -g "$group" -m 0640 "$tmp" /usr/local/etc/xray/config.json
    [[ "$VPS_PARAM_WAS_ACTIVE" == 'false' ]] || systemctl restart xray.service
    ;;
  AnyTlsEntry)
    /usr/local/bin/sing-box-anytls check -c "$tmp"
    install -o root -g sing-box-anytls -m 0640 "$tmp" /etc/sing-box-anytls/config.json
    [[ "$VPS_PARAM_WAS_ACTIVE" == 'false' ]] || systemctl restart sing-box-anytls.service
    ;;
  ShadowsocksLanding)
    /usr/local/bin/sing-box check -c "$tmp"
    install -o root -g sing-box -m 0640 "$tmp" /etc/sing-box/config.json
    [[ "$VPS_PARAM_WAS_ACTIVE" == 'false' ]] || systemctl restart sing-box.service
    ;;
  *) exit 1 ;;
esac
printf '%s\n' 'VPSDEPLOY_CREDENTIAL_CONFIG_APPLIED'
