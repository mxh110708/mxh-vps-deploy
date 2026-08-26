#!/usr/bin/env bash
set -euo pipefail

uuid="$(/usr/local/bin/xray uuid | tr -d '\r\n')"
key_output="$(/usr/local/bin/xray x25519)"
private_key="$(awk -F': *' 'tolower($1) ~ /^private/ {print $2; exit}' <<<"$key_output" | tr -d '\r\n')"
client_key="$(awk -F': *' 'tolower($1) ~ /^(password([[:space:]]*\(publickey\))?|public ?key)/ {print $2; exit}' <<<"$key_output" | tr -d '\r\n')"
short_id="$(openssl rand -hex 8)"

[[ -n "$uuid" && -n "$private_key" && -n "$client_key" && "$short_id" =~ ^[0-9a-f]{16}$ ]] || {
  echo 'Credential generation failed.' >&2
  exit 1
}

python3 - "$uuid" "$private_key" "$client_key" "$short_id" <<'PY'
import base64
import json
import sys

uuid, private_key, client_key, short_id = sys.argv[1:]
payload = json.dumps({
    "Uuid": uuid,
    "RealityPrivateKey": private_key,
    "RealityClientKey": client_key,
    "ShortId": short_id,
}, separators=(",", ":")).encode()
print("VPSDEPLOY_XRAY_SECRET_B64=" + base64.b64encode(payload).decode())
PY
