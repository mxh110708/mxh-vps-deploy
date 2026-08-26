#!/usr/bin/env bash
set -euo pipefail

python3 <<'PY'
import base64, datetime, hashlib, json, os, pathlib, re, socket, subprocess

def run(*args):
    return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def service(name, binary=None, config=None):
    unit = run("systemctl", "cat", name).returncode == 0
    enabled = run("systemctl", "is-enabled", "--quiet", name).returncode == 0
    active = run("systemctl", "is-active", "--quiet", name).returncode == 0
    installed = unit and (not binary or (pathlib.Path(binary).is_file() and os.access(binary, os.X_OK))) and (not config or pathlib.Path(config).is_file())
    return {"Installed": installed, "Enabled": enabled, "Active": active, "UnitLoaded": unit}

def digest(path):
    p = pathlib.Path(path)
    if not p.is_file(): return None
    h = hashlib.sha256()
    with p.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""): h.update(block)
    return h.hexdigest()

def version(command):
    r = run(*command)
    text = r.stdout or r.stderr
    return text.splitlines()[0].strip() if text and (r.returncode == 0 or "Komari Monitor" in text) else None

def first_executable(paths):
    for path in paths:
        if pathlib.Path(path).is_file() and os.access(path, os.X_OK): return path
    return None

sshd = run("sshd", "-T")
ssh = {"Valid": sshd.returncode == 0, "Ports": [], "PasswordAuthentication": None,
       "KbdInteractiveAuthentication": None, "PubkeyAuthentication": None, "PermitRootLogin": None}
for line in sshd.stdout.splitlines():
    key, _, value = line.partition(" ")
    if key == "port" and value.isdigit(): ssh["Ports"].append(int(value))
    elif key in ("passwordauthentication", "kbdinteractiveauthentication", "pubkeyauthentication", "permitrootlogin"):
        ssh[{"passwordauthentication":"PasswordAuthentication", "kbdinteractiveauthentication":"KbdInteractiveAuthentication",
             "pubkeyauthentication":"PubkeyAuthentication", "permitrootlogin":"PermitRootLogin"}[key]] = value
ssh["Ports"] = sorted(set(ssh["Ports"]))

nft_path = "/etc/nftables.conf"
nft_valid = not pathlib.Path(nft_path).exists() or run("nft", "-c", "-f", nft_path).returncode == 0
listeners = run("ss", "-H", "-lntup").stdout
listener_ports = sorted(set(int(x) for x in re.findall(r"(?:\[.*?\]|\S+):(\d+)\s", listeners)))

komari_controller_binary = first_executable(["/opt/komari/komari", "/var/lib/komari/komari", "/usr/local/bin/komari", "/usr/bin/komari"])
cert = {"Present": False, "NotAfter": None, "DaysRemaining": None}
cert_path = pathlib.Path("/etc/mxh-tls/anytls/fullchain.pem")
if cert_path.is_file():
    r = run("openssl", "x509", "-in", str(cert_path), "-noout", "-enddate")
    if r.returncode == 0 and "=" in r.stdout:
        value = r.stdout.strip().split("=",1)[1]
        dt = datetime.datetime.strptime(value, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=datetime.timezone.utc)
        cert = {"Present": True, "NotAfter": dt.isoformat(), "DaysRemaining": int((dt-datetime.datetime.now(datetime.timezone.utc)).total_seconds()//86400)}

paths = {
  "SshMain": "/etc/ssh/sshd_config", "SshManaged": "/etc/ssh/sshd_config.d/00-00-local-access.conf",
  "Xray": "/usr/local/etc/xray/config.json", "AnyTls": "/etc/sing-box-anytls/config.json",
  "Shadowsocks": "/etc/sing-box/config.json", "Nftables": nft_path,
  "Sysctl": "/etc/sysctl.d/99-mxh-vps-deploy.conf", "KomariAgent": "/etc/komari-agent/config.json",
  "KomariControllerUnit": "/etc/systemd/system/komari.service", "CloudflaredUnit": "/etc/systemd/system/cloudflared.service"
}
result = {
 "SchemaVersion": 1, "CollectedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
 "Hostname": socket.gethostname(), "Architecture": os.uname().machine,
 "Ssh": ssh, "ListenerPorts": listener_ports,
 "Services": {
   "RealityEntry": service("xray.service", "/usr/local/bin/xray", "/usr/local/etc/xray/config.json"),
   "AnyTlsEntry": service("sing-box-anytls.service", "/usr/local/bin/sing-box-anytls", "/etc/sing-box-anytls/config.json"),
   "ShadowsocksLanding": service("sing-box.service", "/usr/local/bin/sing-box", "/etc/sing-box/config.json"),
   "KomariAgent": service("komari-agent.service", "/usr/local/bin/komari-agent", "/etc/komari-agent/config.json"),
   "KomariController": service("komari.service"),
   "Cloudflared": service("cloudflared.service")
 },
 "Versions": {
   "Xray": version(["/usr/local/bin/xray","version"]) if pathlib.Path("/usr/local/bin/xray").exists() else None,
   "SingBoxAnyTls": version(["/usr/local/bin/sing-box-anytls","version"]) if pathlib.Path("/usr/local/bin/sing-box-anytls").exists() else None,
   "SingBox": version(["/usr/local/bin/sing-box","version"]) if pathlib.Path("/usr/local/bin/sing-box").exists() else None,
   "KomariAgent": version(["/usr/local/bin/komari-agent","--version"]) if pathlib.Path("/usr/local/bin/komari-agent").exists() else None,
   "KomariController": version([komari_controller_binary,"--version"]) if komari_controller_binary else None
 },
 "Hashes": {name: digest(path) for name,path in paths.items()},
 "Nftables": {"Present": pathlib.Path(nft_path).is_file(), "Valid": nft_valid},
 "Certificate": cert,
 "Timers": {
   "RollbackActive": run("systemctl","is-active","--quiet","mxh-protocol-migration-rollback.timer").returncode == 0,
   "CertbotRenewEnabled": run("systemctl","is-enabled","--quiet","mxh-certbot-renew.timer").returncode == 0
 }
}
payload=json.dumps(result,separators=(",",":")).encode()
print("VPSDEPLOY_HEALTH_AUDIT_B64="+base64.b64encode(payload).decode())
PY
printf '%s\n' 'VPSDEPLOY_HEALTH_AUDIT_OK'
