#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_SOURCE_ROLE:?}"
: "${VPS_PARAM_TARGET_ROLE:?}"
: "${VPS_PARAM_TIMEOUT_MINUTES:?}"

case "$VPS_PARAM_SOURCE_ROLE" in RealityEntry|AnyTlsEntry|ShadowsocksLanding) ;; *) exit 1 ;; esac
case "$VPS_PARAM_TARGET_ROLE" in RealityEntry|AnyTlsEntry|ShadowsocksLanding) ;; *) exit 1 ;; esac
[[ "$VPS_PARAM_SOURCE_ROLE" != "$VPS_PARAM_TARGET_ROLE" ]]
[[ "$VPS_PARAM_TIMEOUT_MINUTES" =~ ^[0-9]+$ ]]
(( VPS_PARAM_TIMEOUT_MINUTES >= 5 && VPS_PARAM_TIMEOUT_MINUTES <= 60 ))

stamp="$(date -u +%Y%m%d-%H%M%S)"
backup_dir="/root/vps-deploy-backups/${stamp}/protocol-migration"
install -d -m 0700 "$backup_dir"
if [[ -f /etc/nftables.conf ]]; then cp -a /etc/nftables.conf "$backup_dir/nftables.conf"; fi
if [[ -f /etc/sysctl.d/99-mxh-vps-deploy.conf ]]; then
  cp -a /etc/sysctl.d/99-mxh-vps-deploy.conf "$backup_dir/99-mxh-vps-deploy.conf"
else
  touch "$backup_dir/sysctl-config-was-absent"
fi
printf '%s\n' "$VPS_PARAM_SOURCE_ROLE" > "$backup_dir/source-role"
printf '%s\n' "$VPS_PARAM_TARGET_ROLE" > "$backup_dir/target-role"
chmod 0600 "$backup_dir/source-role" "$backup_dir/target-role"

install -d -m 0755 /usr/local/libexec
cat > /usr/local/libexec/mxh-protocol-migration-rollback <<'ROLLBACK'
#!/usr/bin/env bash
set -euo pipefail
source_role="$1"
target_role="$2"
backup_dir="$3"
service_for_role() {
  case "$1" in
    RealityEntry) printf '%s' 'xray.service' ;;
    AnyTlsEntry) printf '%s' 'sing-box-anytls.service' ;;
    ShadowsocksLanding) printf '%s' 'sing-box.service' ;;
    *) exit 1 ;;
  esac
}
source_service="$(service_for_role "$source_role")"
target_service="$(service_for_role "$target_role")"
systemctl disable --now "$target_service" >/dev/null 2>&1 || true
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
systemctl enable "$source_service" >/dev/null
systemctl restart "$source_service"
systemctl is-active --quiet "$source_service"
if systemctl is-active --quiet "$target_service"; then exit 1; fi
date -u +%FT%TZ > "$backup_dir/rollback-executed"
ROLLBACK
chmod 0750 /usr/local/libexec/mxh-protocol-migration-rollback

cat > /etc/systemd/system/mxh-protocol-migration-rollback.service <<EOF
[Unit]
Description=Rollback an unconfirmed MXH protocol migration

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/mxh-protocol-migration-rollback $VPS_PARAM_SOURCE_ROLE $VPS_PARAM_TARGET_ROLE $backup_dir
EOF
cat > /etc/systemd/system/mxh-protocol-migration-rollback.timer <<EOF
[Unit]
Description=Rollback timer for an unconfirmed MXH protocol migration

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
