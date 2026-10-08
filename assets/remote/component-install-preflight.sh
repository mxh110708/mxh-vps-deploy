#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_COMPONENT:?}"
python3 <<'PY'
import base64, hashlib, json, os, pathlib, subprocess

component = os.environ['VPS_PARAM_COMPONENT']
definitions = {
 'RealityEntry': ('xray.service', '/usr/local/bin/xray', ['/usr/local/etc/xray', '/usr/local/share/xray', '/etc/systemd/system/xray@.service', '/etc/systemd/system/xray.service.d']),
 'AnyTlsEntry': ('sing-box-anytls.service', '/usr/local/bin/sing-box-anytls', ['/etc/sing-box-anytls', '/var/lib/sing-box-anytls']),
 'ShadowsocksLanding': ('sing-box.service', '/usr/local/bin/sing-box', ['/etc/sing-box', '/var/lib/sing-box', '/etc/systemd/system/sing-box.service.d']),
 'KomariAgent': ('komari-agent.service', '/usr/local/bin/komari-agent', ['/etc/komari-agent', '/var/lib/komari-agent']),
 'KomariController': ('komari.service', '/usr/local/bin/komari', ['/usr/bin/komari', '/opt/komari', '/var/lib/komari']),
 'Tunnel': ('cloudflared.service', '/usr/local/bin/cloudflared', ['/usr/bin/cloudflared', '/etc/cloudflared', '/root/.cloudflared']),
}
if component not in definitions: raise SystemExit('Unsupported installation component')

def run(*args):
    return subprocess.run(args, capture_output=True, text=True, timeout=15)

def digest(path):
    p = pathlib.Path(path)
    if not p.is_file() or p.is_symlink(): return None
    h = hashlib.sha256()
    with p.open('rb') as f:
        for block in iter(lambda: f.read(1048576), b''): h.update(block)
    return h.hexdigest()

def snapshot(name):
    unit, binary, paths = definitions[name]
    configs = {'RealityEntry': '/usr/local/etc/xray/config.json', 'AnyTlsEntry': '/etc/sing-box-anytls/config.json', 'ShadowsocksLanding': '/etc/sing-box/config.json', 'KomariAgent': '/etc/komari-agent/config.json', 'Tunnel': '/etc/cloudflared/mxh-token'}
    return {'Unit': run('systemctl', 'cat', unit).returncode == 0,
            'Enabled': run('systemctl', 'is-enabled', '--quiet', unit).returncode == 0,
            'Active': run('systemctl', 'is-active', '--quiet', unit).returncode == 0,
            'BinaryHash': digest(binary), 'ConfigHash': digest(configs.get(name, '/nonexistent-mxh-config')),
            'UnitHash': digest('/etc/systemd/system/' + unit)}

result = {'Allowed': False, 'Code': 'InstallationCheckIncomplete'}
try:
    services = {name: snapshot(name) for name in definitions}
    unit, binary, paths = definitions[component]
    candidates = [binary, '/etc/systemd/system/' + unit, '/etc/systemd/system/' + unit + '.d', *paths]
    if component == 'AnyTlsEntry' and os.environ.get('VPS_PARAM_CERTIFICATE_PREPARED') != 'true': candidates += ['/etc/mxh-tls/anytls', '/etc/letsencrypt/live/mxh-anytls', '/etc/letsencrypt/renewal/mxh-anytls.conf']
    if os.environ.get('VPS_PARAM_VERIFY_ONLY') == 'true':
        before = json.loads(os.environ['VPS_PARAM_BEFORE_JSON'])['Services']
        preserved = all(services[name] == before[name] for name in definitions if name != component)
        current = services[component]
        result['Code'] = 'ExistingComponentChanged' if not preserved else 'ComponentNotRunning'
        result['Allowed'] = preserved and current['Unit'] and current['Enabled'] and current['Active'] and current['BinaryHash'] is not None
    elif services[component]['Unit'] or services[component]['Enabled'] or services[component]['Active'] or any(pathlib.Path(p).exists() or pathlib.Path(p).is_symlink() or any(parent.is_symlink() for parent in pathlib.Path(p).parents) for p in candidates):
        result['Code'] = 'ComponentExists'
    else:
        ports = [int(port) for port in os.environ.get('VPS_PARAM_PORTS', '').split(',') if port]
        if any(not 1 <= port <= 65535 for port in ports): raise ValueError('Invalid port')
        listeners = [run('ss', '-H', '-lntup', f'sport = :{port}') for port in ports]
        if any(item.returncode != 0 for item in listeners): raise ValueError('Listener check unavailable')
        result['Allowed'] = all(not item.stdout.strip() for item in listeners)
        result['Code'] = 'PortBusy' if not result['Allowed'] else ''
    result['Services'] = services
    result['NftablesSha256'] = digest('/etc/nftables.conf') or ''
except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
    pass
print('VPSDEPLOY_INSTALLATION_CHECK_B64=' + base64.b64encode(json.dumps(result, separators=(',', ':')).encode()).decode())
if os.environ.get('VPS_PARAM_REQUIRE_ABSENT') == 'true' and not result['Allowed']: raise SystemExit(1)
PY
