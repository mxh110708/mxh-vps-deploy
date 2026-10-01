#!/usr/bin/env bash
set -euo pipefail

python3 <<'PY'
import base64, datetime, hashlib, json, os, pathlib, re, socket, subprocess

checks_incomplete = []

def run(*args):
    try:
        return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    except (subprocess.TimeoutExpired, OSError):
        checks_incomplete.append(str(args[0]))
        return subprocess.CompletedProcess(args, 124, "", "read-only check unavailable")

def service(name, binary=None, config=None):
    unit = run("systemctl", "cat", name).returncode == 0
    enabled = run("systemctl", "is-enabled", "--quiet", name).returncode == 0
    active = run("systemctl", "is-active", "--quiet", name).returncode == 0
    installed = unit and (not binary or (pathlib.Path(binary).is_file() and os.access(binary, os.X_OK))) and (not config or pathlib.Path(config).is_file())
    pid_text = run("systemctl", "show", "--property=MainPID", "--value", name).stdout.strip() if active else "0"
    pid = int(pid_text) if pid_text.isdigit() else 0
    matches = None
    if active and binary:
        try: matches = pid > 0 and os.path.samefile(f"/proc/{pid}/exe", binary)
        except OSError: matches = False
    return {"Installed": installed, "Enabled": enabled, "Active": active, "UnitLoaded": unit,
            "ProcessMatchesBinary": matches}

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

def registered_binary(name, supported):
    command = run("systemctl", "show", "--property=ExecStart", "--value", name).stdout
    match = re.search(r"(?:^|\{\s*)path=(.*?)\s*;", command)
    if match and match.group(1) in supported:
        path = pathlib.Path(match.group(1))
        if path.is_file() and os.access(path, os.X_OK): return str(path)
    return None

def certificate(path):
    result = {"Present": False, "NotAfter": None, "DaysRemaining": None}
    if pathlib.Path(path).is_file():
        r = run("openssl", "x509", "-in", path, "-noout", "-enddate")
        if r.returncode == 0 and "=" in r.stdout:
            try:
                dt = datetime.datetime.strptime(r.stdout.strip().split("=",1)[1], "%b %d %H:%M:%S %Y %Z").replace(tzinfo=datetime.timezone.utc)
                result = {"Present": True, "NotAfter": dt.isoformat(), "DaysRemaining": int((dt-datetime.datetime.now(datetime.timezone.utc)).total_seconds()//86400)}
            except ValueError: checks_incomplete.append("certificate")
    return result

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
listener_families = {"Tcp": [], "Udp": []}
for line in listeners.splitlines():
    fields = line.split()
    if len(fields) >= 5 and fields[0] in ("tcp", "udp"):
        match = re.search(r":(\d+)$", fields[4])
        if match: listener_families["Tcp" if fields[0] == "tcp" else "Udp"].append(int(match.group(1)))
listener_families = {key: sorted(set(value)) for key,value in listener_families.items()}

komari_controller_binary = registered_binary("komari.service", ["/opt/komari/komari", "/var/lib/komari/komari", "/usr/local/bin/komari", "/usr/bin/komari"])
cloudflared_binary = registered_binary("cloudflared.service", ["/usr/local/bin/cloudflared", "/usr/bin/cloudflared"])
certificates = {"AnyTls": certificate("/etc/mxh-tls/anytls/fullchain.pem"), "Reality": certificate("/etc/mxh-tls/reality-target/fullchain.pem")}
agent_hash = digest("/usr/local/bin/komari-agent")
agent_releases = json.loads(os.environ.get("VPS_PARAM_AGENT_RELEASES_JSON", "{}"))
# Agent has no version-only command. Identify known releases without executing it.
agent_version = agent_releases.get(agent_hash) if agent_hash else None

paths = {
  "SshMain": "/etc/ssh/sshd_config", "SshManaged": "/etc/ssh/sshd_config.d/00-00-local-access.conf",
  "Xray": "/usr/local/etc/xray/config.json", "AnyTls": "/etc/sing-box-anytls/config.json",
  "Shadowsocks": "/etc/sing-box/config.json", "Nftables": nft_path,
  "Sysctl": "/etc/sysctl.d/99-mxh-vps-deploy.conf", "KomariAgent": "/etc/komari-agent/config.json",
  "KomariControllerUnit": "/etc/systemd/system/komari.service", "CloudflaredUnit": "/etc/systemd/system/cloudflared.service"
}
result = {
 "SchemaVersion": 2, "CollectedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
 "Hostname": socket.gethostname(), "Architecture": os.uname().machine,
 "Ssh": ssh, "ListenerPorts": listener_ports, "Listeners": listener_families,
 "Services": {
   "RealityEntry": service("xray.service", "/usr/local/bin/xray", "/usr/local/etc/xray/config.json"),
   "AnyTlsEntry": service("sing-box-anytls.service", "/usr/local/bin/sing-box-anytls", "/etc/sing-box-anytls/config.json"),
   "ShadowsocksLanding": service("sing-box.service", "/usr/local/bin/sing-box", "/etc/sing-box/config.json"),
   "KomariAgent": service("komari-agent.service", "/usr/local/bin/komari-agent", "/etc/komari-agent/config.json"),
   "KomariController": service("komari.service", komari_controller_binary),
   "Cloudflared": service("cloudflared.service", cloudflared_binary)
 },
 "Versions": {
   "Xray": version(["/usr/local/bin/xray","version"]) if pathlib.Path("/usr/local/bin/xray").exists() else None,
   "SingBoxAnyTls": version(["/usr/local/bin/sing-box-anytls","version"]) if pathlib.Path("/usr/local/bin/sing-box-anytls").exists() else None,
   "SingBox": version(["/usr/local/bin/sing-box","version"]) if pathlib.Path("/usr/local/bin/sing-box").exists() else None,
   "KomariAgent": agent_version,
   "KomariController": version([komari_controller_binary,"--version"]) if komari_controller_binary else None
 },
 "Hashes": {name: digest(path) for name,path in paths.items()},
 "Nftables": {"Present": pathlib.Path(nft_path).is_file(), "Valid": nft_valid},
 "AgentVersionEvidence": {"Sha256": agent_hash, "Identified": agent_version is not None},
 "Certificate": certificates["AnyTls"], "Certificates": certificates,
 "Timers": {
   "RollbackActive": run("systemctl","is-active","--quiet","mxh-protocol-migration-rollback.timer").returncode == 0,
   "CertbotRenewEnabled": run("systemctl","is-enabled","--quiet","mxh-certbot-renew.timer").returncode == 0,
   "CertbotRenewActive": run("systemctl","is-active","--quiet","mxh-certbot-renew.timer").returncode == 0
 },
 "ChecksIncomplete": checks_incomplete
}
payload=json.dumps(result,separators=(",",":")).encode()
print("VPSDEPLOY_HEALTH_AUDIT_B64="+base64.b64encode(payload).decode())
PY
printf '%s\n' 'VPSDEPLOY_HEALTH_AUDIT_OK'
