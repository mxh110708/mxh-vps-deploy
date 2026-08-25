#!/usr/bin/env bash
set -euo pipefail

: "${VPS_PARAM_SOURCE_ROLE:?}"
case "$VPS_PARAM_SOURCE_ROLE" in
  RealityEntry) source_service='xray.service' ;;
  AnyTlsEntry) source_service='sing-box-anytls.service' ;;
  ShadowsocksLanding) source_service='sing-box.service' ;;
  *) exit 1 ;;
esac
systemctl start mxh-protocol-migration-rollback.service
systemctl is-active --quiet "$source_service"
systemctl disable --now mxh-protocol-migration-rollback.timer >/dev/null 2>&1 || true
printf '%s\n' 'VPSDEPLOY_MIGRATION_ROLLBACK_OK'
