#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_PASSWORD:?}"
: "${VPS_PARAM_PORT:?}"
: "${VPS_PARAM_SERVER:?}"
: "${VPS_PARAM_SERVER_NAME:?}"
: "${VPS_PARAM_ECH_CONFIG_PEM:?}"
binary="${VPS_PARAM_SING_BOX_BIN:-/usr/local/bin/sing-box-anytls}"
[[ -x "$binary" ]] || { echo 'sing-box test binary is unavailable.' >&2; exit 1; }

work="$(mktemp -d)"
pid=''
cleanup() {
  if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

read -r mixed_port udp_port udp_fallback_port < <(python3 - <<'PY'
import socket
with socket.socket() as tcp:
    tcp.bind(("127.0.0.1", 0))
    mixed = tcp.getsockname()[1]
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
    udp.bind(("127.0.0.1", 0))
    direct = udp.getsockname()[1]
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
    udp.bind(("127.0.0.1", 0))
    fallback = udp.getsockname()[1]
print(mixed, direct, fallback)
PY
)

python3 - "$work/client.json" "$mixed_port" "$udp_port" "$udp_fallback_port" <<'PY'
import json
import os
import sys

output, mixed_port, udp_port, udp_fallback_port = sys.argv[1:]
config = {
    "log": {"level": "warn"},
    "dns": {"servers": [{"type": "local", "tag": "local"}]},
    "inbounds": [
        {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": int(mixed_port)},
        {
            "type": "direct", "tag": "udp-test-in", "listen": "127.0.0.1",
            "listen_port": int(udp_port), "network": "udp",
            "override_address": "1.1.1.1", "override_port": 53
        },
        {
            "type": "direct", "tag": "udp-fallback-in", "listen": "127.0.0.1",
            "listen_port": int(udp_fallback_port), "network": "udp",
            "override_address": "9.9.9.9", "override_port": 53
        }
    ],
    "outbounds": [{
        "type": "anytls", "tag": "anytls-out", "server": os.environ["VPS_PARAM_SERVER"],
        "server_port": int(os.environ["VPS_PARAM_PORT"]),
        "password": os.environ["VPS_PARAM_PASSWORD"],
        "tls": {
            "enabled": True,
            "server_name": os.environ["VPS_PARAM_SERVER_NAME"],
            "min_version": "1.3",
            "ech": {
                "enabled": True,
                "config": os.environ["VPS_PARAM_ECH_CONFIG_PEM"].strip().splitlines()
            }
        }
    }],
    "route": {"final": "anytls-out"}
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(config, handle, indent=2)
    handle.write("\n")
PY
chmod 0600 "$work/client.json"
"$binary" check -c "$work/client.json"
"$binary" run -c "$work/client.json" >"$work/stdout.log" 2>"$work/stderr.log" &
pid="$!"
sleep 1
kill -0 "$pid"

status=''
for endpoint in 'https://www.gstatic.com/generate_204' 'https://cp.cloudflare.com/generate_204'; do
  status="$(curl --fail --silent --show-error --connect-timeout 10 --max-time 25 \
    --output /dev/null --write-out '%{http_code}' --proxy "http://127.0.0.1:${mixed_port}" "$endpoint" || true)"
  [[ "$status" == '204' ]] && break
done
[[ "$status" == '204' ]]
egress=''
for endpoint in 'https://api64.ipify.org' 'https://icanhazip.com'; do
  egress="$(curl --fail --silent --show-error --connect-timeout 10 --max-time 25 \
    --proxy "http://127.0.0.1:${mixed_port}" "$endpoint" || true)"
  [[ -n "$egress" ]] && break
done
[[ -n "$egress" ]]

python3 - "$udp_port" "$udp_fallback_port" <<'PY'
import os
import socket
import struct
import sys

for value in sys.argv[1:]:
    port = int(value)
    query_id = int.from_bytes(os.urandom(2), "big")
    labels = b"".join(bytes([len(label)]) + label for label in b"example.com".split(b".")) + b"\x00"
    packet = struct.pack("!HHHHHH", query_id, 0x0100, 1, 0, 0, 0) + labels + struct.pack("!HH", 1, 1)
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(10)
            sock.sendto(packet, ("127.0.0.1", port))
            response, _ = sock.recvfrom(4096)
        response_id, flags = struct.unpack("!HH", response[:4]) if len(response) >= 12 else (None, 0)
        if response_id == query_id and flags & 0x8000 and not flags & 0x000F:
            break
    except OSError:
        pass
else:
    raise SystemExit("UDP DNS failed through AnyTLS primary and fallback endpoints.")
PY

printf 'VPSDEPLOY_EGRESS_B64=%s\n' "$(printf '%s' "$egress" | base64 | tr -d '\n')"
printf 'VPSDEPLOY_UDP_B64=%s\n' "$(printf '%s' 'yes' | base64 | tr -d '\n')"
