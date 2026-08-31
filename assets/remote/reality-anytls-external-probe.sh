#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_MIHOMO_VERSION:?}"
: "${VPS_PARAM_MIHOMO_ASSET_NAME:?}"
: "${VPS_PARAM_MIHOMO_SHA256:?}"
: "${VPS_PARAM_SING_BOX_VERSION:?}"
: "${VPS_PARAM_SING_BOX_ASSET_NAME:?}"
: "${VPS_PARAM_SING_BOX_SHA256:?}"
: "${VPS_PARAM_MIHOMO_PROFILE_B64:?}"
: "${VPS_PARAM_SING_BOX_PROFILE_B64:?}"
: "${VPS_PARAM_MIHOMO_PORT:?}"
: "${VPS_PARAM_SING_BOX_PORT:?}"

work="$(mktemp -d)"
pids=()
cleanup() {
  for pid in "${pids[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

download() {
  local url="$1" output="$2" sha256="$3"
  curl --fail --location --silent --show-error --retry 3 --output "$output" "$url"
  printf '%s  %s\n' "$sha256" "$output" | sha256sum --check --status
}

mihomo_archive="$work/$VPS_PARAM_MIHOMO_ASSET_NAME"
download "https://github.com/MetaCubeX/mihomo/releases/download/v${VPS_PARAM_MIHOMO_VERSION#v}/$VPS_PARAM_MIHOMO_ASSET_NAME" \
  "$mihomo_archive" "$VPS_PARAM_MIHOMO_SHA256"
gzip -dc "$mihomo_archive" > "$work/mihomo"
chmod 0755 "$work/mihomo"
mihomo_version_output="$("$work/mihomo" -v)"
grep -qi 'mihomo' <<< "$mihomo_version_output"

sing_archive="$work/$VPS_PARAM_SING_BOX_ASSET_NAME"
download "https://github.com/SagerNet/sing-box/releases/download/v${VPS_PARAM_SING_BOX_VERSION#v}/$VPS_PARAM_SING_BOX_ASSET_NAME" \
  "$sing_archive" "$VPS_PARAM_SING_BOX_SHA256"
tar -xzf "$sing_archive" -C "$work"
sing_box="$(find "$work" -type f -name sing-box -print -quit)"
[[ -n "$sing_box" ]]
chmod 0755 "$sing_box"
sing_box_version_output="$("$sing_box" version)"
grep -qi 'sing-box' <<< "$sing_box_version_output"

printf '%s' "$VPS_PARAM_MIHOMO_PROFILE_B64" | base64 -d > "$work/mihomo.yaml"
printf '%s' "$VPS_PARAM_SING_BOX_PROFILE_B64" | base64 -d > "$work/sing-box.json"

udp_test() {
  python3 - "$1" <<'PY'
import os
import socket
import struct
import sys

port = int(sys.argv[1])
tcp = socket.create_connection(("127.0.0.1", port), timeout=15)
tcp.settimeout(15)
tcp.sendall(b"\x05\x01\x00")
if tcp.recv(2) != b"\x05\x00":
    raise SystemExit("SOCKS5 authentication negotiation failed")
tcp.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
reply = tcp.recv(64)
if len(reply) < 10 or reply[0:2] != b"\x05\x00":
    raise SystemExit("SOCKS5 UDP associate failed")
atyp = reply[3]
if atyp == 1:
    relay_host = socket.inet_ntop(socket.AF_INET, reply[4:8])
    relay_port = struct.unpack("!H", reply[8:10])[0]
elif atyp == 4:
    relay_host = socket.inet_ntop(socket.AF_INET6, reply[4:20])
    relay_port = struct.unpack("!H", reply[20:22])[0]
else:
    raise SystemExit("unexpected SOCKS5 UDP relay address")
if relay_host in ("0.0.0.0", "::"):
    relay_host = "127.0.0.1"
transaction = os.urandom(2)
query = transaction + b"\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
for label in (b"one", b"one", b"one", b"one"):
    query += bytes((len(label),)) + label
query += b"\x00\x00\x01\x00\x01"
packet = b"\x00\x00\x00\x01" + socket.inet_aton("1.1.1.1") + struct.pack("!H", 53) + query
udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp.settimeout(20)
udp.sendto(packet, (relay_host, relay_port))
response, _ = udp.recvfrom(4096)
if len(response) < 22:
    raise SystemExit("short SOCKS5 UDP response")
offset = 10 if response[3] == 1 else 22 if response[3] == 4 else 7 + response[4]
payload = response[offset:]
if len(payload) < 12 or payload[0:2] != transaction or payload[2] & 0x80 == 0:
    raise SystemExit("invalid UDP DNS response")
udp.close()
tcp.close()
PY
}

wait_port() {
  local port="$1"
  for _ in $(seq 1 30); do
    if bash -c "</dev/tcp/127.0.0.1/$port" 2>/dev/null; then return 0; fi
    sleep 0.2
  done
  return 1
}

run_acceptance() {
  local core="$1" port="$2" log="$3"
  shift 3
  "$@" > "$log" 2>&1 &
  local pid=$!
  pids+=("$pid")
  wait_port "$port"
  kill -0 "$pid"
  local endpoint='' code=''
  for candidate in 'https://www.gstatic.com/generate_204' 'https://cp.cloudflare.com/generate_204'; do
    code="$(curl --silent --show-error --max-time 25 --proxy "http://127.0.0.1:$port" --output /dev/null --write-out '%{http_code}' "$candidate" || true)"
    if [[ "$code" == '204' ]]; then endpoint="$candidate"; break; fi
  done
  [[ -n "$endpoint" ]] || { sed -n '1,80p' "$log" >&2; return 1; }
  local egress
  egress="$(curl --fail --silent --show-error --max-time 25 --proxy "http://127.0.0.1:$port" https://api64.ipify.org)"
  local family
  family="$(python3 - "$egress" <<'PY'
import ipaddress, sys
print('IPv6' if ipaddress.ip_address(sys.argv[1].strip()).version == 6 else 'IPv4')
PY
)"
  udp_test "$port"
  printf '%s\t%s\t%s\t%s\n' "$core" "$endpoint" "$egress" "$family" >> "$work/results.tsv"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

mkdir -p "$work/mihomo-data"
run_acceptance mihomo "$VPS_PARAM_MIHOMO_PORT" "$work/mihomo.log" \
  "$work/mihomo" -d "$work/mihomo-data" -f "$work/mihomo.yaml"
run_acceptance sing-box "$VPS_PARAM_SING_BOX_PORT" "$work/sing-box.log" \
  "$sing_box" run -c "$work/sing-box.json"

python3 - "$work/results.tsv" <<'PY'
import base64
import json
import sys

results = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        core, endpoint, egress, family = line.rstrip("\n").split("\t")
        results.append({"core": core, "https_endpoint": endpoint, "egress": egress, "egress_family": family, "udp": "Passed"})
payload = json.dumps({"status": "Passed", "results": results}, separators=(",", ":")).encode()
print("VPSDEPLOY_EXTERNAL_ACCEPTANCE_B64=" + base64.b64encode(payload).decode())
print("VPSDEPLOY_EXTERNAL_ACCEPTANCE_OK")
PY
