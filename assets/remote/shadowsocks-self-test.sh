#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_METHOD:?}"
: "${VPS_PARAM_PASSWORD:?}"
: "${VPS_PARAM_LANDING_PORT:?}"
: "${VPS_PARAM_IP_VERSION:?}"
: "${VPS_PARAM_TEST_SERVER:?}"

work="$(mktemp -d)"
pid=''
cleanup() {
  if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

mixed_port="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"

strategy='ipv4_only'
check_url='https://api.ipify.org'
if [[ "$VPS_PARAM_IP_VERSION" == '6' ]]; then
  strategy='ipv6_only'
  check_url='https://api64.ipify.org'
fi

python3 - "$work/client.json" "$mixed_port" "$strategy" <<'PY'
import json
import os
import sys

output, mixed_port, strategy = sys.argv[1:]
config = {
    "log": {"level": "warn"},
    "dns": {"servers": [{"type": "local", "tag": "local"}]},
    "inbounds": [{
        "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1",
        "listen_port": int(mixed_port)
    }],
    "outbounds": [{
        "type": "shadowsocks", "tag": "ss-out", "server": os.environ["VPS_PARAM_TEST_SERVER"],
        "server_port": int(os.environ["VPS_PARAM_LANDING_PORT"]),
        "method": os.environ["VPS_PARAM_METHOD"],
        "password": os.environ["VPS_PARAM_PASSWORD"],
        "domain_resolver": {"server": "local", "strategy": strategy}
    }],
    "route": {"final": "ss-out"},
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(config, handle, indent=2)
    handle.write("\n")
PY
chmod 0600 "$work/client.json"
/usr/local/bin/sing-box check -c "$work/client.json"
/usr/local/bin/sing-box run -c "$work/client.json" >"$work/stdout.log" 2>"$work/stderr.log" &
pid="$!"
sleep 1
kill -0 "$pid"
egress="$(curl --fail --silent --show-error --connect-timeout 10 --max-time 25 \
  --proxy "http://127.0.0.1:${mixed_port}" "$check_url")"
[[ -n "$egress" ]] || { echo 'Empty Shadowsocks egress result.' >&2; exit 1; }
printf 'VPSDEPLOY_EGRESS_B64=%s\n' "$(printf '%s' "$egress" | base64 | tr -d '\n')"
