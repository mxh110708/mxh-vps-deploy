#!/usr/bin/env bash
set -euo pipefail
: "${VPS_PARAM_ACTION:?}"

find_controller_binary() {
  local command_line
  command_line="$(systemctl show --property=ExecStart --value komari.service)"
  python3 - "$command_line" /opt/komari/komari /var/lib/komari/komari /usr/local/bin/komari /usr/bin/komari <<'PY'
import os, pathlib, re, sys
command, *supported = sys.argv[1:]
match = re.search(r"(?:^|\{\s*)path=(.*?)\s*;", command)
if not match or match.group(1) not in supported:
    raise SystemExit("Unsupported Komari service executable; automatic upgrade is refused")
binary = pathlib.Path(match.group(1))
if binary.is_symlink() or not binary.is_file() or not os.access(binary, os.X_OK):
    raise SystemExit("Komari service executable is missing, not executable or symlinked")
print(match.group(1))
PY
}

assert_controller_storage() {
  local working_directory command_line
  systemctl cat komari.service >/dev/null
  find_controller_binary >/dev/null
  working_directory="$(systemctl show --property=WorkingDirectory --value komari.service)"
  command_line="$(systemctl show --property=ExecStart --value komari.service)"
  python3 - "$working_directory" "$command_line" /opt/komari /var/lib/komari <<'PY'
import pathlib, re, shlex, sys
working, command, *supported = sys.argv[1:]
roots = [pathlib.Path(value) for value in supported]
root = pathlib.Path(working)
if not working or root not in roots or root.resolve() != root:
    raise SystemExit("Unsupported Komari working/data directory; use a verified manual backup")
match = re.search(r"argv\[\]=(.*?)\s*;", command)
if not match:
    raise SystemExit("Unable to verify Komari service arguments before backup")
arguments = shlex.split(match.group(1))
database = "./data/komari.db"
database_type = "sqlite"
index = 1
while index < len(arguments):
    argument = arguments[index]
    if argument in ("--database", "-d", "--db-type", "-t"):
        if index + 1 >= len(arguments):
            raise SystemExit("Incomplete Komari database argument")
        if argument in ("--database", "-d"):
            database = arguments[index + 1]
        else:
            database_type = arguments[index + 1]
        index += 1
    elif argument.startswith("--database="):
        database = argument.split("=", 1)[1]
    elif argument.startswith("--db-type="):
        database_type = argument.split("=", 1)[1]
    elif argument.startswith("-d") and len(argument) > 2:
        database = argument[2:].removeprefix("=")
    elif argument.startswith("-t") and len(argument) > 2:
        database_type = argument[2:].removeprefix("=")
    index += 1
if database_type.lower() != "sqlite":
    raise SystemExit("Komari 1.5 supports SQLite; automatic upgrade of this database type is refused")
if not database or database.startswith("file:") or "?" in database or "#" in database:
    raise SystemExit("Unsupported Komari database path or DSN; use a verified manual backup")
database_path = pathlib.Path(database)
resolved = (database_path if database_path.is_absolute() else root / database_path).resolve()
if not any(resolved == allowed or allowed in resolved.parents for allowed in roots):
    raise SystemExit("Komari database is outside the supported snapshot directories; automatic upgrade is refused")
PY
}

verify_controller() {
  local binary code pending body pid
  binary="$(find_controller_binary)"
  [[ "${VPS_PARAM_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  grep -Fq "Komari Monitor ${VPS_PARAM_VERSION}" <<<"$("$binary" --version 2>&1 || true)"
  pending=deferred
  if systemctl is-active --quiet komari.service; then
    for _ in {1..30}; do grep -Fq '127.0.0.1:25774' <<< "$(ss -H -lnt 'sport = :25774' 2>/dev/null)" && break; sleep 1; done
    grep -Fq '127.0.0.1:25774' <<< "$(ss -H -lnt 'sport = :25774')"
    pid="$(systemctl show --property=MainPID --value komari.service)"
    [[ "$pid" =~ ^[1-9][0-9]*$ && "/proc/${pid}/exe" -ef "$binary" ]]
    code="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 http://127.0.0.1:25774/)"
    [[ "$code" =~ ^(200|302|303|307|308|401|403)$ ]]
    body="$(mktemp)"
    if ! code="$(curl --silent --output "$body" --write-out '%{http_code}' --max-time 10 http://127.0.0.1:25774/api/admin/database-migration/auth)"; then rm -f "$body"; return 1; fi
    case "$code" in
      404) pending=false ;;
      200)
        if ! pending="$(python3 - "$body" <<'PY'
import json, sys
body = open(sys.argv[1], encoding="utf-8").read()
# The normal 1.5 SPA router returns index.html for unregistered GET routes.
# HTML alone is not proof of completion: verify the normal version API below.
if body.lstrip().lower().startswith(("<!doctype html", "<html")):
    print("false")
    raise SystemExit(0)
value = json.loads(body)
data = value.get("data") if isinstance(value, dict) else None
if not isinstance(data, dict) or data.get("mode") not in ("legacy_monitoring", "metric_store_restructure"):
    raise SystemExit("Unexpected Komari migration response")
print("true")
PY
        )"
        then rm -f "$body"; return 1; fi
        ;;
      *) rm -f "$body"; echo 'Unable to verify Komari database migration state.' >&2; return 1 ;;
    esac
    if [[ "$pending" == false ]]; then
      if ! code="$(curl --silent --output "$body" --write-out '%{http_code}' --max-time 10 http://127.0.0.1:25774/api/version)" || [[ "$code" != 200 ]]; then rm -f "$body"; return 1; fi
      if ! python3 - "$body" "$VPS_PARAM_VERSION" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
data = value.get("data") if isinstance(value, dict) else None
if not isinstance(data, dict) or str(data.get("version", "")).removeprefix("v") != sys.argv[2]:
    raise SystemExit("Normal Komari version API does not confirm the expected version")
PY
      then rm -f "$body"; return 1; fi
    fi
    rm -f "$body"
  fi
  printf 'VPSDEPLOY_KOMARI_MIGRATION_REQUIRED_B64=%s\n' "$(printf '%s' "$pending" | base64 | tr -d '\n')"
}

case "$VPS_PARAM_ACTION" in
  ControllerPreflight) assert_controller_storage ;;
  ControllerVerify) verify_controller ;;
  Status)
    for service in komari-agent.service komari.service cloudflared.service; do
      installed=false; enabled=false; active=false
      systemctl cat "$service" >/dev/null 2>&1 && installed=true
      systemctl is-enabled --quiet "$service" 2>/dev/null && enabled=true
      systemctl is-active --quiet "$service" 2>/dev/null && active=true
      printf '%s=%s,%s,%s\n' "$service" "$installed" "$enabled" "$active"
    done
    ;;
  AgentUninstall)
    systemctl disable --now komari-agent.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/komari-agent.service /usr/local/bin/komari-agent
    rm -rf /etc/komari-agent /var/lib/komari-agent
    systemctl daemon-reload
    ;;
  AgentUpgrade)
    : "${VPS_PARAM_VERSION:?}"; : "${VPS_PARAM_ASSET_NAME:?}"; : "${VPS_PARAM_SHA256:?}"
    [[ "$VPS_PARAM_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$VPS_PARAM_SHA256" =~ ^[0-9a-f]{64}$ ]]
    [[ -s /etc/komari-agent/config.json ]]
    systemctl cat komari-agent.service >/dev/null
    case "$(uname -m)" in x86_64|amd64) arch=amd64;; aarch64|arm64) arch=arm64;; *) exit 1;; esac
    [[ "$VPS_PARAM_ASSET_NAME" == "komari-agent-linux-${arch}" ]]
    was_active=false; was_enabled=false
    systemctl is-active --quiet komari-agent.service 2>/dev/null && was_active=true
    systemctl is-enabled --quiet komari-agent.service 2>/dev/null && was_enabled=true
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    curl --fail --location --silent --show-error --retry 3 --output "$tmp" "https://github.com/komari-monitor/komari-agent/releases/download/${VPS_PARAM_VERSION}/${VPS_PARAM_ASSET_NAME}"
    printf '%s  %s\n' "$VPS_PARAM_SHA256" "$tmp" | sha256sum --check --status
    # Agent 1.5.11 has no version command. Never execute a downloaded agent
    # for preflight: its normal entry point may start persistent workers.
    # The pinned release checksum identifies the exact version instead.
    install -o root -g root -m 0755 "$tmp" /usr/local/bin/komari-agent
    printf '%s  %s\n' "$VPS_PARAM_SHA256" /usr/local/bin/komari-agent | sha256sum --check --status
    if [[ "$was_active" == true ]]; then
      systemctl restart komari-agent.service
      for _ in {1..10}; do
        pid="$(systemctl show --property=MainPID --value komari-agent.service)"
        if systemctl is-active --quiet komari-agent.service && [[ "$pid" =~ ^[1-9][0-9]*$ && "/proc/${pid}/exe" -ef /usr/local/bin/komari-agent ]]; then break; fi
        sleep 1
      done
      systemctl is-active --quiet komari-agent.service
      [[ "$pid" =~ ^[1-9][0-9]*$ && "/proc/${pid}/exe" -ef /usr/local/bin/komari-agent ]]
      printf '%s  %s\n' "$VPS_PARAM_SHA256" "/proc/${pid}/exe" | sha256sum --check --status
    fi
    if [[ "$was_enabled" == false ]]; then systemctl disable komari-agent.service >/dev/null 2>&1 || true; fi
    ;;
  ControllerBackup)
    assert_controller_storage
    stamp="$(date -u +%Y%m%d-%H%M%S)"; output="/root/komari-controller-${stamp}.tar.gz"
    [[ ! -e "$output" ]] || { echo 'Komari backup timestamp collision; retry later.' >&2; exit 1; }
    paths=(); for p in var/lib/komari opt/komari etc/systemd/system/komari.service etc/systemd/system/cloudflared.service usr/local/bin/komari usr/bin/komari usr/local/bin/cloudflared usr/bin/cloudflared; do [[ -e "/$p" ]] && paths+=("$p"); done
    ((${#paths[@]} > 0))
    backup_was_active=false; systemctl is-active --quiet komari.service && backup_was_active=true
    restart_after_backup(){ [[ "$backup_was_active" == false ]] || systemctl start komari.service; }
    trap restart_after_backup EXIT
    if [[ "$backup_was_active" == true ]]; then systemctl stop komari.service; fi
    tar --numeric-owner -czpf "$output" -C / "${paths[@]}"; chmod 0600 "$output"
    restart_after_backup; trap - EXIT
    printf 'VPSDEPLOY_KOMARI_BACKUP_B64=%s\n' "$(printf '%s' "$output" | base64 | tr -d '\n')"
    ;;
  ControllerRestore)
    : "${VPS_PARAM_BACKUP_FILE:?}"; final_active="${VPS_PARAM_FINAL_ACTIVE:-true}"
    [[ "$final_active" == true || "$final_active" == false ]]
    file="$(readlink -f "$VPS_PARAM_BACKUP_FILE")"
    [[ "$file" =~ ^/root/komari-controller-[0-9]{8}-[0-9]{6}\.tar\.gz$ ]]; tar -tzf "$file" >/dev/null
    stamp="$(date -u +%Y%m%d-%H%M%S)"; safety="/root/vps-deploy-backups/${stamp}/komari-controller-restore"
    install -d -m 0700 "$safety"; current=()
    for p in var/lib/komari opt/komari etc/systemd/system/komari.service etc/systemd/system/cloudflared.service usr/local/bin/komari usr/local/bin/cloudflared usr/bin/cloudflared; do [[ -e "/$p" ]] && current+=("$p"); done
    ((${#current[@]} == 0)) || tar --numeric-owner -czpf "$safety/current.tar.gz" -C / "${current[@]}"
    was_enabled=false; was_active=false; tunnel_was_enabled=false; tunnel_was_active=false
    systemctl is-enabled --quiet komari.service 2>/dev/null && was_enabled=true
    systemctl is-active --quiet komari.service 2>/dev/null && was_active=true
    systemctl is-enabled --quiet cloudflared.service 2>/dev/null && tunnel_was_enabled=true
    systemctl is-active --quiet cloudflared.service 2>/dev/null && tunnel_was_active=true
    rollback(){ set +e; systemctl disable --now cloudflared.service komari.service >/dev/null 2>&1; [[ ! -f "$safety/current.tar.gz" ]] || tar --numeric-owner -xzpf "$safety/current.tar.gz" -C /; systemctl daemon-reload; [[ "$was_enabled" == false ]] || systemctl enable komari.service >/dev/null; [[ "$was_active" == false ]] || systemctl start komari.service; [[ "$tunnel_was_enabled" == false ]] || systemctl enable cloudflared.service >/dev/null; [[ "$tunnel_was_active" == false ]] || systemctl start cloudflared.service; }
    on_restore_exit(){ local rc=$?; trap - EXIT; if ((rc != 0)); then rollback; fi; exit "$rc"; }
    trap on_restore_exit EXIT
    systemctl stop cloudflared.service komari.service >/dev/null 2>&1 || true
    tar --numeric-owner -xzpf "$file" -C /; systemctl daemon-reload
    systemctl enable --now komari.service >/dev/null
    for _ in {1..30}; do grep -Fq '127.0.0.1:25774' <<< "$(ss -H -lnt 'sport = :25774' 2>/dev/null)" && break; sleep 1; done
    grep -Fq '127.0.0.1:25774' <<< "$(ss -H -lntp 'sport = :25774')"
    code="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 http://127.0.0.1:25774/)"
    [[ "$code" =~ ^(200|302|303|307|308|401|403)$ ]]
    if [[ "$final_active" == false ]]; then systemctl disable --now komari.service >/dev/null 2>&1 || true; fi
    trap - EXIT
    printf 'VPSDEPLOY_BACKUP_DIR_B64=%s\n' "$(printf '%s' "$safety" | base64 | tr -d '\n')"
    ;;
  ControllerUpgrade)
    assert_controller_storage
    : "${VPS_PARAM_VERSION:?}"; : "${VPS_PARAM_ASSET_NAME:?}"; : "${VPS_PARAM_SHA256:?}"
    : "${VPS_PARAM_BACKUP_FILE:?}"
    rollback_backup="$(readlink -f "$VPS_PARAM_BACKUP_FILE")"
    [[ "$rollback_backup" =~ ^/root/komari-controller-[0-9]{8}-[0-9]{6}\.tar\.gz$ ]]; tar -tzf "$rollback_backup" >/dev/null
    for directory in /var/lib/komari /opt/komari; do [[ ! -L "$directory" ]] || { echo 'Unsupported symlinked Komari data directory.' >&2; exit 1; }; done
    case "$(uname -m)" in x86_64|amd64) arch=amd64;; aarch64|arm64) arch=arm64;; *) exit 1;; esac
    [[ "$VPS_PARAM_ASSET_NAME" == "komari-linux-${arch}" ]]
    binary="$(find_controller_binary)"; systemctl cat komari.service >/dev/null
    was_active=false; was_enabled=false; systemctl is-active --quiet komari.service && was_active=true; systemctl is-enabled --quiet komari.service 2>/dev/null && was_enabled=true
    tmp="$(mktemp)"; previous="$(mktemp)"; cp -a "$binary" "$previous"
    binary_changed=false
    rollback_upgrade(){
      [[ "$binary_changed" == true ]] || return 0
      systemctl stop komari.service
      local failed_dir directory leaf
      failed_dir="$(mktemp -d /root/vps-deploy-backups/komari-failed-upgrade-XXXXXXXX)"
      chmod 0700 "$failed_dir"
      for directory in /var/lib/komari /opt/komari; do
        [[ -d "$directory" ]] || continue
        [[ ! -L "$directory" && "$(readlink -f "$directory")" == "$directory" ]] || return 1
        leaf="${directory#/}"; mv "$directory" "$failed_dir/${leaf//\//-}"
      done
      tar --numeric-owner -xzpf "$rollback_backup" -C /
      install -o root -g root -m 0755 "$previous" "$binary"
      systemctl daemon-reload
      [[ "$was_active" == false ]] || systemctl start komari.service
      [[ "$was_enabled" == false ]] && systemctl disable komari.service >/dev/null 2>&1 || true
    }
    on_upgrade_exit(){ local rc=$?; trap - EXIT; if ((rc != 0)); then rollback_upgrade; fi; rm -f "$tmp" "$previous"; exit "$rc"; }
    trap on_upgrade_exit EXIT
    curl --fail --location --silent --show-error --retry 3 --output "$tmp" "https://github.com/komari-monitor/komari/releases/download/${VPS_PARAM_VERSION}/${VPS_PARAM_ASSET_NAME}"
    printf '%s  %s\n' "$VPS_PARAM_SHA256" "$tmp" | sha256sum --check --status
    systemctl stop komari.service >/dev/null 2>&1 || true
    binary_changed=true
    install -o root -g root -m 0755 "$tmp" "$binary"
    version_output="$("$binary" --version 2>&1 || true)"; grep -Fq "Komari Monitor ${VPS_PARAM_VERSION}" <<<"$version_output"
    if [[ "$was_active" == true ]]; then systemctl start komari.service; systemctl is-active --quiet komari.service; fi
    verify_controller
    if [[ "$was_enabled" == false ]]; then systemctl disable komari.service >/dev/null 2>&1 || true; fi
    trap - EXIT; rm -f "$tmp" "$previous"
    ;;
  TunnelRotate)
    : "${VPS_PARAM_TUNNEL_TOKEN:?}"
    [[ "$VPS_PARAM_TUNNEL_TOKEN" != *[[:space:]]* ]]
    cloudflared_bin="$(command -v cloudflared)"; [[ -x "$cloudflared_bin" ]]
    cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel for Komari
Wants=network-online.target
After=network-online.target komari.service
[Service]
Type=simple
ExecStart=${cloudflared_bin} tunnel --no-autoupdate run --token ${VPS_PARAM_TUNNEL_TOKEN}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
[Install]
WantedBy=multi-user.target
EOF
    chmod 0600 /etc/systemd/system/cloudflared.service
    systemctl daemon-reload; systemctl enable --now cloudflared.service >/dev/null
    systemctl is-active --quiet cloudflared.service
    ;;
  ControllerUninstall)
    systemctl disable --now cloudflared.service komari.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/cloudflared.service /etc/systemd/system/komari.service /usr/local/bin/cloudflared /usr/local/bin/komari
    rm -rf /var/lib/komari /opt/komari
    systemctl daemon-reload
    ;;
  *) exit 1 ;;
esac
printf '%s\n' 'VPSDEPLOY_KOMARI_LIFECYCLE_OK'
