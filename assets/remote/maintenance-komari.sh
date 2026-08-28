#!/usr/bin/env bash
set -euo pipefail
: "${VPS_PARAM_ACTION:?}"
case "$VPS_PARAM_ACTION" in
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
    [[ -s /etc/komari-agent/config.json ]]
    case "$(uname -m)" in x86_64|amd64) arch=amd64;; aarch64|arm64) arch=arm64;; *) exit 1;; esac
    [[ "$VPS_PARAM_ASSET_NAME" == *"-${arch}" ]]
    was_active=false; was_enabled=false
    systemctl is-active --quiet komari-agent.service 2>/dev/null && was_active=true
    systemctl is-enabled --quiet komari-agent.service 2>/dev/null && was_enabled=true
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    curl --fail --location --silent --show-error --retry 3 --output "$tmp" "https://github.com/komari-monitor/komari-agent/releases/download/${VPS_PARAM_VERSION}/${VPS_PARAM_ASSET_NAME}"
    printf '%s  %s\n' "$VPS_PARAM_SHA256" "$tmp" | sha256sum --check --status
    install -o root -g root -m 0755 "$tmp" /usr/local/bin/komari-agent
    if [[ "$was_active" == true ]]; then systemctl restart komari-agent.service; systemctl is-active --quiet komari-agent.service; fi
    if [[ "$was_enabled" == false ]]; then systemctl disable komari-agent.service >/dev/null 2>&1 || true; fi
    ;;
  ControllerBackup)
    stamp="$(date -u +%Y%m%d-%H%M%S)"; output="/root/komari-controller-${stamp}.tar.gz"
    paths=(); for p in var/lib/komari/data var/lib/komari/komari opt/komari etc/systemd/system/komari.service etc/systemd/system/cloudflared.service usr/local/bin/komari usr/local/bin/cloudflared usr/bin/cloudflared; do [[ -e "/$p" ]] && paths+=("$p"); done
    ((${#paths[@]} > 0)); tar --numeric-owner -czpf "$output" -C / "${paths[@]}"; chmod 0600 "$output"
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
    was_enabled=false; was_active=false; systemctl is-enabled --quiet komari.service 2>/dev/null && was_enabled=true; systemctl is-active --quiet komari.service 2>/dev/null && was_active=true
    rollback(){ set +e; systemctl disable --now cloudflared.service komari.service >/dev/null 2>&1; [[ ! -f "$safety/current.tar.gz" ]] || tar --numeric-owner -xzpf "$safety/current.tar.gz" -C /; systemctl daemon-reload; [[ "$was_enabled" == false ]] || systemctl enable komari.service >/dev/null; [[ "$was_active" == false ]] || systemctl start komari.service; }
    on_restore_exit(){ local rc=$?; trap - EXIT; if ((rc != 0)); then rollback; fi; exit "$rc"; }
    trap on_restore_exit EXIT
    systemctl stop cloudflared.service komari.service >/dev/null 2>&1 || true
    tar --numeric-owner -xzpf "$file" -C /; systemctl daemon-reload
    systemctl enable --now komari.service >/dev/null
    ss -H -lntp 'sport = :25774' | grep -Fq '127.0.0.1:25774'
    if [[ "$final_active" == false ]]; then systemctl disable --now komari.service >/dev/null 2>&1 || true; fi
    trap - EXIT
    printf 'VPSDEPLOY_BACKUP_DIR_B64=%s\n' "$(printf '%s' "$safety" | base64 | tr -d '\n')"
    ;;
  ControllerUpgrade)
    : "${VPS_PARAM_VERSION:?}"; : "${VPS_PARAM_ASSET_NAME:?}"; : "${VPS_PARAM_SHA256:?}"
    case "$(uname -m)" in x86_64|amd64) arch=amd64;; aarch64|arm64) arch=arm64;; *) exit 1;; esac
    [[ "$VPS_PARAM_ASSET_NAME" == "komari-linux-${arch}" ]]
    binary=''; for candidate in /opt/komari/komari /var/lib/komari/komari /usr/local/bin/komari /usr/bin/komari; do [[ -x "$candidate" ]] && binary="$candidate" && break; done
    [[ -n "$binary" ]]; systemctl cat komari.service >/dev/null
    was_active=false; was_enabled=false; systemctl is-active --quiet komari.service && was_active=true; systemctl is-enabled --quiet komari.service 2>/dev/null && was_enabled=true
    tmp="$(mktemp)"; previous="$(mktemp)"; cp -a "$binary" "$previous"
    rollback_upgrade(){ set +e; systemctl stop komari.service >/dev/null 2>&1 || true; install -o root -g root -m 0755 "$previous" "$binary"; [[ "$was_active" == false ]] || systemctl start komari.service; [[ "$was_enabled" == false ]] && systemctl disable komari.service >/dev/null 2>&1 || true; }
    on_upgrade_exit(){ local rc=$?; trap - EXIT; if ((rc != 0)); then rollback_upgrade; fi; rm -f "$tmp" "$previous"; exit "$rc"; }
    trap on_upgrade_exit EXIT
    curl --fail --location --silent --show-error --retry 3 --output "$tmp" "https://github.com/komari-monitor/komari/releases/download/${VPS_PARAM_VERSION}/${VPS_PARAM_ASSET_NAME}"
    printf '%s  %s\n' "$VPS_PARAM_SHA256" "$tmp" | sha256sum --check --status
    systemctl stop komari.service >/dev/null 2>&1 || true
    install -o root -g root -m 0755 "$tmp" "$binary"
    version_output="$("$binary" --version 2>&1 || true)"; grep -Fq "Komari Monitor ${VPS_PARAM_VERSION}" <<<"$version_output"
    if [[ "$was_active" == true ]]; then
      systemctl start komari.service; systemctl is-active --quiet komari.service
      for _ in {1..30}; do ss -H -lnt 'sport = :25774' 2>/dev/null | grep -Fq '127.0.0.1:25774' && break; sleep 1; done
      ss -H -lnt 'sport = :25774' | grep -Fq '127.0.0.1:25774'
      code="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 http://127.0.0.1:25774/)"
      [[ "$code" =~ ^(200|302|303|307|308|401|403)$ ]]
    fi
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
