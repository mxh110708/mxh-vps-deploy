#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_SOURCE_ROLE:?}"
: "${VPS_PARAM_TARGET_ROLE:?}"
: "${VPS_PARAM_TIMEOUT_MINUTES:?}"

case "$VPS_PARAM_SOURCE_ROLE" in RealityEntry|AnyTlsEntry|ShadowsocksLanding|MonitorOnly) ;; *) exit 1 ;; esac
case "$VPS_PARAM_TARGET_ROLE" in RealityEntry|AnyTlsEntry|ShadowsocksLanding|MonitorOnly) ;; *) exit 1 ;; esac
[[ "$VPS_PARAM_TIMEOUT_MINUTES" =~ ^[0-9]+$ ]]
(( VPS_PARAM_TIMEOUT_MINUTES >= 5 && VPS_PARAM_TIMEOUT_MINUTES <= 60 ))

stamp="$(date -u +%Y%m%d-%H%M%S)"
backup_dir="/root/vps-deploy-backups/${stamp}/protocol-lifecycle"
install -d -m 0700 "$backup_dir"
if [[ -f /etc/nftables.conf ]]; then cp -a /etc/nftables.conf "$backup_dir/nftables.conf"; fi
if [[ -f /etc/sysctl.d/99-mxh-vps-deploy.conf ]]; then
  cp -a /etc/sysctl.d/99-mxh-vps-deploy.conf "$backup_dir/99-mxh-vps-deploy.conf"
else
  touch "$backup_dir/sysctl-config-was-absent"
fi
printf '%s\n' "$VPS_PARAM_SOURCE_ROLE" > "$backup_dir/source-role"
printf '%s\n' "$VPS_PARAM_TARGET_ROLE" > "$backup_dir/target-role"

service_snapshot() {
  local role="$1" service="$2" binary="$3" config="$4"
  local installed='false' enabled='false' active='false'
  if [[ -x "$binary" && -s "$config" ]] && systemctl cat "$service" >/dev/null 2>&1; then installed='true'; fi
  systemctl is-enabled --quiet "$service" 2>/dev/null && enabled='true'
  systemctl is-active --quiet "$service" 2>/dev/null && active='true'
  printf '%s\n' "$installed" > "$backup_dir/${role}.installed"
  printf '%s\n' "$enabled" > "$backup_dir/${role}.enabled"
  printf '%s\n' "$active" > "$backup_dir/${role}.active"
}
service_snapshot RealityEntry xray.service /usr/local/bin/xray /usr/local/etc/xray/config.json
service_snapshot AnyTlsEntry sing-box-anytls.service /usr/local/bin/sing-box-anytls /etc/sing-box-anytls/config.json
service_snapshot ShadowsocksLanding sing-box.service /usr/local/bin/sing-box /etc/sing-box/config.json
nginx_enabled='false'
nginx_active='false'
systemctl is-enabled --quiet nginx.service 2>/dev/null && nginx_enabled='true'
systemctl is-active --quiet nginx.service 2>/dev/null && nginx_active='true'
printf '%s\n' "$nginx_enabled" > "$backup_dir/NginxRealityTarget.enabled"
printf '%s\n' "$nginx_active" > "$backup_dir/NginxRealityTarget.active"

candidate_paths=(
  usr/local/bin/xray usr/local/etc/xray usr/local/share/xray
  etc/systemd/system/xray.service etc/systemd/system/xray@.service etc/systemd/system/xray.service.d
  etc/nginx/sites-available/mxh-reality-target etc/nginx/sites-enabled/mxh-reality-target var/www/mxh-reality-target
  usr/local/bin/sing-box-anytls etc/systemd/system/sing-box-anytls.service etc/sing-box-anytls var/lib/sing-box-anytls
  usr/local/bin/sing-box etc/systemd/system/sing-box.service etc/systemd/system/sing-box.service.d etc/sing-box var/lib/sing-box
)
existing_paths=()
for relative in "${candidate_paths[@]}"; do
  if [[ -e "/$relative" || -L "/$relative" ]]; then existing_paths+=("$relative"); fi
done
if (( ${#existing_paths[@]} > 0 )); then
  tar --numeric-owner -czpf "$backup_dir/protocol-files.tar.gz" -C / "${existing_paths[@]}"
fi
chmod -R go-rwx "$backup_dir"

install -d -m 0755 /usr/local/libexec
cat > /usr/local/libexec/mxh-protocol-migration-rollback <<'ROLLBACK'
#!/usr/bin/env bash
set -euo pipefail
backup_dir="$1"

cleanup_role() {
  case "$1" in
    RealityEntry)
      rm -f /usr/local/bin/xray /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
      rm -rf /usr/local/etc/xray /usr/local/share/xray /etc/systemd/system/xray.service.d
      rm -f /etc/nginx/sites-enabled/mxh-reality-target /etc/nginx/sites-available/mxh-reality-target
      rm -rf /var/www/mxh-reality-target
      ;;
    AnyTlsEntry)
      rm -f /usr/local/bin/sing-box-anytls /etc/systemd/system/sing-box-anytls.service
      rm -rf /etc/sing-box-anytls /var/lib/sing-box-anytls
      ;;
    ShadowsocksLanding)
      rm -f /usr/local/bin/sing-box /etc/systemd/system/sing-box.service
      rm -rf /etc/systemd/system/sing-box.service.d /etc/sing-box /var/lib/sing-box
      ;;
  esac
}

for service in xray.service sing-box-anytls.service sing-box.service; do
  systemctl disable --now "$service" >/dev/null 2>&1 || true
done
for role in RealityEntry AnyTlsEntry ShadowsocksLanding; do
  if [[ "$(cat "$backup_dir/${role}.installed")" == 'false' ]]; then cleanup_role "$role"; fi
done
if [[ -f "$backup_dir/protocol-files.tar.gz" ]]; then
  tar --numeric-owner -xzpf "$backup_dir/protocol-files.tar.gz" -C /
fi
if [[ -f "$backup_dir/nftables.conf" ]]; then
  cp -a "$backup_dir/nftables.conf" /etc/nftables.conf
  nft -c -f /etc/nftables.conf
  nft -f /etc/nftables.conf
fi
if [[ -f "$backup_dir/99-mxh-vps-deploy.conf" ]]; then
  cp -a "$backup_dir/99-mxh-vps-deploy.conf" /etc/sysctl.d/99-mxh-vps-deploy.conf
elif [[ -f "$backup_dir/sysctl-config-was-absent" ]]; then
  rm -f /etc/sysctl.d/99-mxh-vps-deploy.conf
fi
sysctl --system >/dev/null
systemctl daemon-reload

restore_service() {
  local role="$1" service="$2" enabled active
  enabled="$(cat "$backup_dir/${role}.enabled")"
  active="$(cat "$backup_dir/${role}.active")"
  if [[ "$enabled" == 'true' ]]; then systemctl enable "$service" >/dev/null; else systemctl disable "$service" >/dev/null 2>&1 || true; fi
  if [[ "$active" == 'true' ]]; then systemctl start "$service"; else systemctl stop "$service" >/dev/null 2>&1 || true; fi
  if [[ "$enabled" == 'true' ]]; then systemctl is-enabled --quiet "$service"; else ! systemctl is-enabled --quiet "$service" 2>/dev/null; fi
  if [[ "$active" == 'true' ]]; then systemctl is-active --quiet "$service"; else ! systemctl is-active --quiet "$service" 2>/dev/null; fi
}
restore_service RealityEntry xray.service
restore_service AnyTlsEntry sing-box-anytls.service
restore_service ShadowsocksLanding sing-box.service
if command -v nginx >/dev/null 2>&1; then
  nginx_enabled="$(cat "$backup_dir/NginxRealityTarget.enabled")"
  nginx_active="$(cat "$backup_dir/NginxRealityTarget.active")"
  if [[ "$nginx_enabled" == 'true' ]]; then systemctl enable nginx.service >/dev/null; else systemctl disable nginx.service >/dev/null 2>&1 || true; fi
  if [[ "$nginx_active" == 'true' ]]; then
    nginx -t
    systemctl start nginx.service
  else
    systemctl stop nginx.service >/dev/null 2>&1 || true
  fi
fi
date -u +%FT%TZ > "$backup_dir/rollback-executed"
ROLLBACK
chmod 0750 /usr/local/libexec/mxh-protocol-migration-rollback

cat > /etc/systemd/system/mxh-protocol-migration-rollback.service <<EOF
[Unit]
Description=Rollback an unconfirmed MXH protocol lifecycle change

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/mxh-protocol-migration-rollback $backup_dir
EOF
cat > /etc/systemd/system/mxh-protocol-migration-rollback.timer <<EOF
[Unit]
Description=Rollback timer for an unconfirmed MXH protocol lifecycle change

[Timer]
OnActiveSec=${VPS_PARAM_TIMEOUT_MINUTES}min
AccuracySec=1s
Unit=mxh-protocol-migration-rollback.service

[Install]
WantedBy=timers.target
EOF
chmod 0644 /etc/systemd/system/mxh-protocol-migration-rollback.service \
  /etc/systemd/system/mxh-protocol-migration-rollback.timer
systemctl daemon-reload
systemctl enable --now mxh-protocol-migration-rollback.timer >/dev/null
systemctl is-active --quiet mxh-protocol-migration-rollback.timer
printf 'VPSDEPLOY_BACKUP_DIR_B64=%s\n' "$(printf '%s' "$backup_dir" | base64 | tr -d '\n')"
printf '%s\n' 'VPSDEPLOY_MIGRATION_ROLLBACK_ARMED'
