#!/usr/bin/env bash
set -euo pipefail

service_state() {
  local role="$1"
  local service="$2"
  local binary="$3"
  local config="$4"
  local unit_loaded='false'
  local binary_present='false'
  local config_present='false'
  local enabled='false'
  local active='false'

  systemctl cat "$service" >/dev/null 2>&1 && unit_loaded='true'
  [[ -x "$binary" ]] && binary_present='true'
  [[ -s "$config" ]] && config_present='true'
  systemctl is-enabled --quiet "$service" 2>/dev/null && enabled='true'
  systemctl is-active --quiet "$service" 2>/dev/null && active='true'

  local installed='false'
  local partial='false'
  if [[ "$unit_loaded" == 'true' && "$binary_present" == 'true' && "$config_present" == 'true' ]]; then
    installed='true'
  elif [[ "$unit_loaded" == 'true' || "$binary_present" == 'true' || "$config_present" == 'true' ]]; then
    partial='true'
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$role" "$installed" "$enabled" "$active" "$partial" "$service"
}

inventory="$({
  service_state RealityEntry xray.service /usr/local/bin/xray /usr/local/etc/xray/config.json
  service_state AnyTlsEntry sing-box-anytls.service /usr/local/bin/sing-box-anytls /etc/sing-box-anytls/config.json
  service_state ShadowsocksLanding sing-box.service /usr/local/bin/sing-box /etc/sing-box/config.json
} | python3 -c '
import json, sys
result = {"SchemaVersion": 1}
for line in sys.stdin:
    role, installed, enabled, active, partial, service = line.rstrip("\n").split("\t")
    result[role] = {
        "Installed": installed == "true",
        "Enabled": enabled == "true",
        "Active": active == "true",
        "Partial": partial == "true",
        "Service": service,
    }
print(json.dumps(result, separators=(",", ":")))
')"

python3 - "$inventory" <<'PY'
import json
import sys

inventory = json.loads(sys.argv[1])
for role in ("RealityEntry", "AnyTlsEntry", "ShadowsocksLanding"):
    item = inventory[role]
    if item["Partial"]:
        raise SystemExit(f"Partial managed protocol installation detected: {role}")
    if (item["Enabled"] or item["Active"]) and not item["Installed"]:
        raise SystemExit(f"Service state exists without a complete installation: {role}")
if inventory["RealityEntry"]["Enabled"] and inventory["AnyTlsEntry"]["Enabled"]:
    raise SystemExit("Reality and AnyTLS cannot both be enabled")
if inventory["RealityEntry"]["Active"] and inventory["AnyTlsEntry"]["Active"]:
    raise SystemExit("Reality and AnyTLS cannot both be active")
PY

printf 'VPSDEPLOY_PROTOCOL_INVENTORY_B64=%s\n' "$(printf '%s' "$inventory" | base64 | tr -d '\n')"
printf '%s\n' 'VPSDEPLOY_PROTOCOL_STATUS_OK'
