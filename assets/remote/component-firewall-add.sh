#!/usr/bin/env bash
set -euo pipefail
: "${VPS_PARAM_COMPONENT:?}"
: "${VPS_PARAM_PORTS:?}"
: "${VPS_PARAM_EXPECTED_SHA256:?}"
[[ -f /etc/nftables.conf && ! -L /etc/nftables.conf ]]
temporary="$(mktemp)"
trap 'rm -f "$temporary"' EXIT
python3 - "$temporary" <<'PY'
import hashlib, ipaddress, os, pathlib, sys
path = pathlib.Path('/etc/nftables.conf')
data = path.read_bytes()
if hashlib.sha256(data).hexdigest() != os.environ['VPS_PARAM_EXPECTED_SHA256']: raise SystemExit('Firewall changed after review')
text = data.decode()
anchor = '    ct state established,related accept\n'
if text.count(anchor) != 1 or text.count('table inet filter {') != 1 or text.count('  chain input {') != 1: raise SystemExit('Unsupported managed firewall layout')
ports = [int(p) for p in os.environ['VPS_PARAM_PORTS'].split(',')]
if any(not 1 <= p <= 65535 for p in ports): raise SystemExit('Invalid port')
lines = []
if os.environ['VPS_PARAM_COMPONENT'] == 'ShadowsocksLanding':
    for variable, family, prefix in [('VPS_PARAM_ALLOWED_IPV4S', 4, 'ip'), ('VPS_PARAM_ALLOWED_IPV6S', 6, 'ip6')]:
        values = [str(ipaddress.ip_address(v)) for v in os.environ.get(variable, '').split(',') if v]
        if any(ipaddress.ip_address(v).version != family for v in values): raise SystemExit('Invalid address family')
        for protocol in ('tcp', 'udp'):
            if values: lines.append(f"    {prefix} saddr {{ {','.join(values)} }} {protocol} dport {ports[0]} accept\n")
    if not lines: raise SystemExit('Missing trusted entries')
elif os.environ['VPS_PARAM_COMPONENT'] in ('RealityEntry', 'AnyTlsEntry'):
    lines.append('    tcp dport { ' + ','.join(map(str, ports)) + ' } accept\n')
else: raise SystemExit('Unsupported component')
pathlib.Path(sys.argv[1]).write_text(text.replace(anchor, anchor + ''.join(lines)), encoding='utf-8')
PY
nft -c -f "$temporary"
if declare -F vps_transaction_check >/dev/null; then vps_transaction_check; fi
[[ "$(sha256sum /etc/nftables.conf | cut -d' ' -f1)" == "$VPS_PARAM_EXPECTED_SHA256" ]]
install -o root -g root -m 0755 "$temporary" /etc/nftables.conf
nft -f /etc/nftables.conf
systemctl is-active --quiet nftables.service
printf '%s\n' 'VPSDEPLOY_COMPONENT_FIREWALL_OK'
