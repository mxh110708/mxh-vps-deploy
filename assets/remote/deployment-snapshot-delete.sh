#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_SNAPSHOT_DIR:?}"
: "${VPS_PARAM_KIND:?}"
snapshot="$VPS_PARAM_SNAPSHOT_DIR"
case "$VPS_PARAM_KIND" in
  deployment-aborted-before-mutations)
    root='/root/vps-deploy-transaction-baselines'
    [[ "$snapshot" =~ ^${root}/[a-f0-9]{32}$ ]]
    if [[ ! -e "$snapshot" ]]; then
      printf '%s\n' 'VPSDEPLOY_SNAPSHOT_DELETE_OK'
      exit 0
    fi
    resolved="$(readlink -f "$snapshot")"
    [[ "$resolved" == "$snapshot" ]]
    rm -rf -- "$resolved"
    rmdir -- "$root" 2>/dev/null || true
    printf '%s\n' 'VPSDEPLOY_SNAPSHOT_DELETE_OK'
    exit 0
    ;;
  deployment-committed|deployment-rolled-back)
    root='/root/vps-deploy-transaction-baselines'
    [[ "$snapshot" =~ ^${root}/[a-f0-9]{32}$ ]]
    if [[ "$VPS_PARAM_KIND" == 'deployment-rolled-back' && ! -e "$snapshot" ]]; then
      printf '%s\n' 'VPSDEPLOY_SNAPSHOT_DELETE_OK'
      exit 0
    fi
    resolved="$(readlink -f "$snapshot")"
    [[ "$resolved" == "$snapshot" ]]
    [[ "$(dirname "$resolved")" == "$root" ]]
    [[ "$(basename "$resolved")" =~ ^[a-f0-9]{32}$ ]]
    [[ -f "$resolved/baseline.complete" ]]
    if [[ "$VPS_PARAM_KIND" == 'deployment-rolled-back' ]]; then
      [[ -f "$resolved/rollback.complete" && -f "$resolved/backup-directories.before" ]]
      if [[ -d /root/vps-deploy-backups ]]; then
        while IFS= read -r candidate; do
          [[ "$candidate" =~ ^[0-9]{8}-[0-9]{6}$ ]] || continue
          grep -qxF "$candidate" "$resolved/backup-directories.before" && continue
          candidate_path="/root/vps-deploy-backups/$candidate"
          [[ "$(readlink -f "$candidate_path")" == "$candidate_path" ]]
          for component in ssh certbot-dns local-https-target nftables sysctl \
            sing-box-anytls-install sing-box-anytls sing-box-install sing-box \
            ssh-cutover xray; do
            [[ -e "$candidate_path/$component" || -L "$candidate_path/$component" ]] || continue
            rm -rf -- "$candidate_path/$component"
          done
          rmdir -- "$candidate_path" 2>/dev/null || true
        done < <(find /root/vps-deploy-backups -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
      fi
    fi
    ;;
  protocol-rolled-back)
    root='/root/vps-deploy-backups'
    [[ "$snapshot" =~ ^${root}/[0-9]{8}-[0-9]{6}/protocol-lifecycle$ ]]
    if [[ ! -e "$snapshot" ]]; then
      printf '%s\n' 'VPSDEPLOY_SNAPSHOT_DELETE_OK'
      exit 0
    fi
    resolved="$(readlink -f "$snapshot")"
    [[ "$resolved" == "$snapshot" ]]
    [[ -f "$resolved/rollback-executed" ]]
    systemctl disable --now mxh-protocol-migration-rollback.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/mxh-protocol-migration-rollback.timer \
      /etc/systemd/system/mxh-protocol-migration-rollback.service \
      /usr/local/libexec/mxh-protocol-migration-rollback
    systemctl daemon-reload
    ;;
  *) exit 1 ;;
esac
rm -rf -- "$resolved"
rmdir -- "$(dirname "$resolved")" 2>/dev/null || true
printf '%s\n' 'VPSDEPLOY_SNAPSHOT_DELETE_OK'
