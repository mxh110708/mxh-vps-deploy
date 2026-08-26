#!/usr/bin/env bash
set -euo pipefail
: "${VPS_PARAM_CONFIRM:?}"
[[ "$VPS_PARAM_CONFIRM" == 'WIPE-REMOTE-BACKUPS' ]]
! systemctl is-active --quiet mxh-protocol-migration-rollback.timer 2>/dev/null
root=/root/vps-deploy-backups
if [[ -d "$root" ]]; then
  resolved="$(readlink -f "$root")"; [[ "$resolved" == /root/vps-deploy-backups ]]; rm -rf -- "$resolved"
fi
rm -f /etc/systemd/system/mxh-protocol-migration-rollback.timer /etc/systemd/system/mxh-protocol-migration-rollback.service /usr/local/libexec/mxh-protocol-migration-rollback
systemctl daemon-reload
printf '%s\n' 'VPSDEPLOY_DECOMMISSION_FINALIZED'
