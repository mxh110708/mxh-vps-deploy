#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_SOURCE_ROLE:?}"
: "${VPS_PARAM_EXPECTED_BACKUP:?}"
if [[ -f "$VPS_PARAM_EXPECTED_BACKUP/rollback-executed" && ! -f /var/lib/mxh-vps-deploy/transaction.owner ]]; then
  printf '%s\n' 'VPSDEPLOY_MIGRATION_ROLLBACK_OK'; exit 0
fi
[[ "$(cat /var/lib/mxh-vps-deploy/transaction.owner)" == "$VPS_PARAM_EXPECTED_BACKUP" ]]
case "$VPS_PARAM_SOURCE_ROLE" in RealityEntry|AnyTlsEntry|ShadowsocksLanding|MonitorOnly) ;; *) exit 1 ;; esac
systemctl start mxh-protocol-migration-rollback.service
! systemctl is-failed --quiet mxh-protocol-migration-rollback.service
[[ -f "$VPS_PARAM_EXPECTED_BACKUP/rollback-executed" ]]
systemctl disable --now mxh-protocol-migration-rollback.timer >/dev/null 2>&1 || true
printf '%s\n' 'VPSDEPLOY_MIGRATION_ROLLBACK_OK'
