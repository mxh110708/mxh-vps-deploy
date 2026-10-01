#!/usr/bin/env bash
set -euo pipefail
: "${VPS_PARAM_ROLE:?}"
case "$VPS_PARAM_ROLE" in
  RealityEntry) config=/usr/local/etc/xray/config.json ;;
  AnyTlsEntry) config=/etc/sing-box-anytls/config.json ;;
  ShadowsocksLanding) config=/etc/sing-box/config.json ;;
  *) exit 1 ;;
esac
python3 - "$config" <<'PY'
import base64, hashlib, json, pathlib, sys
raw = pathlib.Path(sys.argv[1]).read_bytes()
config = json.loads(raw)
if not isinstance(config, dict): raise SystemExit("Invalid managed config")
print("VPSDEPLOY_SERVER_CONFIG_B64=" + base64.b64encode(json.dumps(config, separators=(",", ":")).encode()).decode())
print("VPSDEPLOY_SERVER_CONFIG_SHA256_B64=" + base64.b64encode(hashlib.sha256(raw).hexdigest().encode()).decode())
PY
