#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_METHOD:?}"
: "${VPS_PARAM_PASSWORD:?}"
: "${VPS_PARAM_LANDING_PORT:?}"
: "${VPS_PARAM_IP_VERSION:?}"
: "${VPS_PARAM_TEST_SERVER:?}"
sing_box_bin="${VPS_PARAM_SING_BOX_BIN:-/usr/local/bin/sing-box}"
[[ -x "$sing_box_bin" ]] || { echo 'sing-box test binary is unavailable.' >&2; exit 1; }

work="$(mktemp -d)"
pid=''
phase='prepare'
cleanup() {
  if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT INT TERM
trap 'status=$?; printf "VPSDEPLOY_SELFTEST_FAILURE_PHASE=%s\n" "$phase" >&2; exit "$status"' ERR

mixed_port="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"

udp_port="$(python3 - <<'PY'
import socket
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"

strategy='ipv4_only'
check_url='https://api.ipify.org'
udp_target='1.1.1.1'
udp_query_type='1'
if [[ "$VPS_PARAM_IP_VERSION" == '6' ]]; then
  strategy='ipv6_only'
  check_url='https://api64.ipify.org'
  udp_target='2606:4700:4700::1111'
  udp_query_type='28'
fi

python3 - "$work/client.json" "$mixed_port" "$udp_port" "$strategy" "$udp_target" <<'PY'
import json
import os
import sys

output, mixed_port, udp_port, strategy, udp_target = sys.argv[1:]
config = {
    "log": {"level": "warn"},
    "dns": {"servers": [{"type": "local", "tag": "local"}]},
    "inbounds": [
        {
            "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1",
            "listen_port": int(mixed_port)
        },
        {
            "type": "direct", "tag": "udp-test-in", "listen": "127.0.0.1",
            "listen_port": int(udp_port), "network": "udp",
            "override_address": udp_target, "override_port": 53
        }
    ],
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
phase='config-check'
"$sing_box_bin" check -c "$work/client.json"
phase='client-start'
"$sing_box_bin" run -c "$work/client.json" >"$work/stdout.log" 2>"$work/stderr.log" &
pid="$!"
sleep 1
kill -0 "$pid"
phase='https'
egress="$(curl --fail --silent --show-error --connect-timeout 10 --max-time 25 \
  --proxy "http://127.0.0.1:${mixed_port}" "$check_url")"
[[ -n "$egress" ]] || { echo 'Empty Shadowsocks egress result.' >&2; exit 1; }

phase='udp'
python3 - "$udp_port" "$udp_query_type" <<'PY'
import os
import socket
import struct
import sys

port = int(sys.argv[1])
query_type = int(sys.argv[2])
query_id = int.from_bytes(os.urandom(2), "big")
labels = b"".join(bytes([len(label)]) + label for label in b"example.com".split(b".")) + b"\x00"
packet = struct.pack("!HHHHHH", query_id, 0x0100, 1, 0, 0, 0) + labels + struct.pack("!HH", query_type, 1)
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.settimeout(10)
    sock.sendto(packet, ("127.0.0.1", port))
    response, _ = sock.recvfrom(4096)
if len(response) < 12:
    raise SystemExit("Short UDP DNS response through Shadowsocks.")
response_id, flags = struct.unpack("!HH", response[:4])
if response_id != query_id or not flags & 0x8000 or flags & 0x000F:
    raise SystemExit("Invalid UDP DNS response through Shadowsocks.")
PY

phase='complete'
printf 'VPSDEPLOY_EGRESS_B64=%s\n' "$(printf '%s' "$egress" | base64 | tr -d '\n')"
printf 'VPSDEPLOY_UDP_B64=%s\n' "$(printf '%s' 'yes' | base64 | tr -d '\n')"
