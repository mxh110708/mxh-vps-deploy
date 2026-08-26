#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_SOURCE_ROLE:?}"
case "$VPS_PARAM_SOURCE_ROLE" in RealityEntry|AnyTlsEntry|ShadowsocksLanding|MonitorOnly) ;; *) exit 1 ;; esac
systemctl start mxh-protocol-migration-rollback.service
! systemctl is-failed --quiet mxh-protocol-migration-rollback.service
systemctl disable --now mxh-protocol-migration-rollback.timer >/dev/null 2>&1 || true
printf '%s\n' 'VPSDEPLOY_MIGRATION_ROLLBACK_OK'
